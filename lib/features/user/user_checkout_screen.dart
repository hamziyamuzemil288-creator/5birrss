import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/availability_notice.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/cart_service.dart';
import '../../core/services/fee_resolver.dart';
import '../../core/services/location_prompt.dart';
import '../../core/services/location_service.dart';
import '../../core/widgets/where_to_picker.dart';
import 'user_payment_screen.dart';

class UserCheckoutScreen extends ConsumerStatefulWidget {
  final String providerId;

  /// The lines this checkout is for. Empty means "everything this buyer has
  /// from this provider", which is what the cart's own CHECKOUT means; a
  /// non-empty list is the buyer's explicit choice from the availability gate
  /// (a single tapped listing, or several they ticked).
  ///
  /// It is applied by filtering the cart read below, so the order the payment
  /// screen submits can never be bigger than what the provider was asked
  /// about.
  final List<String> productIds;

  const UserCheckoutScreen({
    super.key,
    required this.providerId,
    this.productIds = const [],
  });
  @override
  ConsumerState<UserCheckoutScreen> createState() => _UserCheckoutScreenState();
}

class _UserCheckoutScreenState extends ConsumerState<UserCheckoutScreen> {
  List<CartItem> _items = [];
  bool _loading = true;
  String? _error;
  final _addressCtrl = TextEditingController();

  // The buyer, as a guest gives them. A guest has no profile worth reading at
  // the door, so the three fields delivery actually needs are collected here
  // and written onto the order by order-create. Nothing else is asked for:
  // no registration, no document, no verification.
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  /// The buyer no longer CHOOSES a fulfillment mode. A purchase is delivered;
  /// a BOOKING (a service, a room) happens at the provider, exactly as it did
  /// before, so a haircut does not demand a shipping address. That second case
  /// is decided by the basket itself, never by a pickup card — the old "I go
  /// to them" option is gone from the screen and from the price.
  String _fulfillmentMode = 'DELIVERY';

  /// True once the buyer has explicitly chosen how an order arrives. Nothing
  /// in this build offers that choice, so the automatic booking default is
  /// never at risk of overwriting a decision — the flag is kept so a future
  /// mode picker cannot reintroduce the bug where a reload reset it.
  bool _fulfillmentTouched = false;

  /// Every line in the basket is an appointment rather than a parcel.
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

  /// Set when the SERVER refused the delivery for being past
  /// `max_delivery_distance_km`. Delivery is the only option, so the card
  /// explains why and CONTINUE is blocked — there is no second mode to quietly
  /// move the buyer to. Never decided here: the refusal comes back as
  /// `BEYOND_MAX_DISTANCE` from the same quote that prices the trip.
  bool _deliveryBeyondMax = false;

  /// The server's own sentence for [_deliveryBeyondMax], shown verbatim so the
  /// number it names (the distance and the cap) is the one the server measured.
  String? _deliveryRefusal;

  /// The delivery fee actually added to the total: zero unless the server
  /// priced this delivery. A failed or unpriceable quote contributes NOTHING
  /// rather than an invented number.
  double get _deliveryFee =>
      _fulfillmentMode == 'DELIVERY' && (_deliveryQuote?.hasValue ?? false)
          ? _deliveryQuote!.fee!
          : 0.0;

  /// What the buyer pays: the product display prices plus the delivery fee
  /// when the server has priced one.
  double get _payableTotal => _total + _deliveryFee;

  /// True when at least one item in this cart is a listing whose provider
  /// must confirm it is available before the buyer pays.
  ///
  /// Snapshotted onto the order by `create_order_secure` at the moment the
  /// order is created, so the gate cannot move under a buyer after they have
  /// paid. Read here from the products themselves, best-effort: a database
  /// that has not run migration 20260927000074 has no such column, the read
  /// raises, and the flag stays false — the order is then placed exactly as
  /// it was before this feature existed.
  ///
  /// The payment screen receives it as `paymentDeferred` and shows the shared
  /// AvailabilityNotice instead of the accounts, which is the behaviour this
  /// screen had before the payment step moved.
  bool _needsAvailabilityConfirmation = false;

  /// The provider's display name, read once for the payment step's header.
  /// Readiness — whether they have paid the registration fee and have a
  /// balance to cover the transaction fee — is checked on the PAYMENT screen,
  /// immediately before the order is submitted, because that is the moment it
  /// matters; checking it here would be a second, earlier opinion nobody acts
  /// on.
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

  /// The provider's business name, for the payment step's header. Non-fatal:
  /// on failure the name stays the generic one and nothing else changes.
  Future<void> _loadProviderName() async {
    try {
      final prov = await Supabase.instance.client
          .from('public_provider_profiles')
          .select('business_name')
          .eq('id', widget.providerId)
          .maybeSingle();
      final name = prov?['business_name'] as String?;
      if (name != null && name.isNotEmpty) _providerName = name;
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _addressCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final all = await CartService.instance.getCart();
      final forProvider =
          all.where((i) => i.providerId == widget.providerId).toList();
      // The buyer's selection wins. Falling back to the whole provider basket
      // only when no selection was passed keeps the cart's own CHECKOUT
      // working exactly as it did.
      final wanted = widget.productIds.toSet();
      final items = wanted.isEmpty
          ? forProvider
          : forProvider.where((i) => wanted.contains(i.productId)).toList();
      // A basket of bookings stays a booking. The server has no delivery to
      // price and the buyer has nowhere to receive a haircut, so the order is
      // created in the mode the service flow already uses; nothing on screen
      // offers it as a choice.
      if (!_fulfillmentTouched &&
          items.isNotEmpty &&
          items.every((i) => i.isBooking)) {
        _fulfillmentMode = 'SELF_PICKUP';
      } else if (!_fulfillmentTouched) {
        _fulfillmentMode = 'DELIVERY';
      }
      // Read the provider's name for the payment step's header.
      await _loadProviderName();
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
      // No buyer document is read anywhere any more: a buyer is a guest and
      // verifies nothing. The checkout only decides how the order arrives.

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
            context.pushReplacement('/user/availability', extra: {
              'providerId': widget.providerId,
              'productIds': ids,
            });
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
    // The map point IS the delivery location, so it seeds the address line
    // when the buyer has not typed one: the server still requires an address
    // ("Delivery requires an address"), and asking for the same thing twice —
    // once on the map, once in a text field — is how a working delivery step
    // looks like it is stuck. A buyer who already wrote their own keeps it.
    if (_addressCtrl.text.trim().isEmpty &&
        chosen.label.trim().isNotEmpty) {
      _addressCtrl.text = chosen.label.trim();
    }
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

    // Past the cap the server refuses instead of pricing. Delivery is the only
    // option now, so the refusal is shown in place and CONTINUE is blocked —
    // there is no fallback mode to quietly move the buyer to.
    final beyondMax =
        !quote.ok && quote.reason == 'BEYOND_MAX_DISTANCE';
    setState(() {
      _deliveryQuote = quote;
      _deliveryQuoting = false;
      _deliveryBeyondMax = beyondMax;
      _deliveryRefusal = beyondMax ? quote.message : null;
    });
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
          else if (quote != null && quote.hasValue) ...[
            Text(
              'Distance ${quote.distanceKm?.toStringAsFixed(2) ?? '—'} km · '
              'delivery fee ${quote.fee!.toStringAsFixed(2)} $currency '
              '(${_deliveryVehicleName ?? 'this vehicle'} rate)',
              style: const TextStyle(fontSize: 12.5, height: 1.35),
            ),
            const SizedBox(height: 4),
            // The exact wording the buyer must see under every quoted price.
            const Text(
              'This is a default estimate — the actual price may vary '
              'depending on your exact location.',
              style: TextStyle(
                  fontSize: 11.5, height: 1.4, color: AppTheme.textMuted),
            ),
          ]
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
        ],
      ),
    );
  }

  /// A booking happens at the provider. This is an explanation, never a
  /// choice: there is no delivery fee and no vehicle for a service, and the
  /// order keeps the mode the booking flow has always used.
  Widget _bookingNote() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.teal.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.teal.withOpacity(0.3)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.event_available_outlined, size: 18, color: AppTheme.teal),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'This is a booking — the provider serves you at their place, so '
              'there is no delivery address, vehicle or delivery fee.',
              style: TextStyle(fontSize: 12.5, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  /// Hands the settled basket to the payment step, which is its own screen.
  ///
  /// Everything about HOW the order arrives is decided by now — the mode, the
  /// delivery vehicle, the delivery point and the server's delivery quote — so
  /// the draft carries those across and the payment screen's job is only the
  /// money: the platform's account, what the buyer wrote down, the proof and
  /// the order-create call.
  void _continueToPayment() {
    if (_items.isEmpty) {
      setState(() => _error = 'Your cart is empty for this provider');
      return;
    }
    // Delivery is the only way an order arrives, so the three things a
    // delivery actually needs are required here, next to the fields that
    // collect them. The server refuses the same three.
    final name = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    final address = _addressCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Add the name of the person receiving the order.');
      return;
    }
    if (RegExp(r'^[+0-9][0-9\s-]{6,19}$').hasMatch(phone) == false) {
      setState(() => _error =
          'Add a valid phone number so the driver can reach you.');
      return;
    }
    if (_fulfillmentMode == 'DELIVERY' && address.isEmpty) {
      setState(() => _error = 'Add the delivery address.');
      return;
    }
    // The pin is what the driver navigates to and what the buyer's tracking
    // map draws a route to. An address line alone cannot be turned into a
    // destination, so it is required, and it can be placed by hand on the map
    // when GPS is unavailable. A booking has no delivery and needs neither.
    if (_fulfillmentMode == 'DELIVERY' &&
        (_deliveryLat == null || _deliveryLng == null)) {
      setState(() => _error =
          'Set the delivery point on the map so the driver can find you.');
      return;
    }
    if (_fulfillmentMode == 'DELIVERY' && _deliveryBeyondMax) {
      setState(() => _error = _deliveryRefusal ??
          'Delivery is not available this far away.');
      return;
    }
    context.push(
      '/user/payment',
      extra: OrderDraft(
        providerId: widget.providerId,
        providerName: _providerName,
        items: List<CartItem>.from(_items),
        fulfillmentMode: _fulfillmentMode,
        deliveryAddress: address,
        deliveryLat: _deliveryLat,
        deliveryLng: _deliveryLng,
        deliveryVehicleId: _deliveryVehicleId,
        deliveryVehicleName: _deliveryVehicleName,
        deliveryFee: _deliveryFee,
        deliveryDistanceKm: _deliveryQuote?.distanceKm,
        paymentDeferred: _needsAvailabilityConfirmation,
        commissionPreview: _commissionPreview,
        buyerName: name,
        buyerPhone: phone,
        buyerNote: _notesCtrl.text.trim(),
      ),
    );
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
                            // sum. Before a delivery has been priced there is
                            // one line, exactly as before.
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
                      // DELIVERY ONLY for a purchase. The old two-card choice
                      // (delivery vs self-pickup) is gone, together with its
                      // price branch, its note and its strings. A BOOKING is
                      // the one exception, and it is not a choice: a service
                      // happens at the provider, so the screen says so instead
                      // of asking for a shipping address the service cannot
                      // use. Old pickup orders keep rendering.
                      Text(_isBookingCart ? 'Your details' : 'Delivery details',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(
                        _isBookingCart
                            ? 'Only what the booking needs. No account and no '
                                'documents.'
                            : 'Only what the delivery needs. No account and no '
                                'documents.',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textMuted),
                      ),
                      const SizedBox(height: 12),
                      BirrTextField(
                        label: 'Your name',
                        controller: _nameCtrl,
                        hint: 'Who is receiving the order',
                        textCapitalization: TextCapitalization.words,
                      ),
                      const SizedBox(height: 12),
                      BirrTextField(
                        label: 'Phone number',
                        controller: _phoneCtrl,
                        keyboardType: TextInputType.phone,
                        hint: _isBookingCart
                            ? 'The provider calls this number'
                            : 'The driver calls this number',
                      ),
                      if (!_isBookingCart) ...[
                        const SizedBox(height: 12),
                        BirrTextField(
                          label: 'Delivery address',
                          controller: _addressCtrl,
                          maxLines: 2,
                          hint: 'Street, area, city',
                        ),
                      ],
                      const SizedBox(height: 12),
                      BirrTextField(
                        label: _isBookingCart
                            ? 'Notes for the provider (optional)'
                            : 'Notes for the driver (optional)',
                        controller: _notesCtrl,
                        maxLines: 2,
                        hint: _isBookingCart
                            ? 'Anything they should know before you arrive'
                            : 'Landmark, floor, gate…',
                      ),
                      const SizedBox(height: 14),
                      if (_isBookingCart) _bookingNote() else _deliveryReceipt(),
                      const SizedBox(height: 16),
                      // Delivery refused as too far: said once, in full, right
                      // under the fields — the number in it is the one the
                      // server measured, so the buyer can see WHY rather than
                      // guessing.
                      if (!_isBookingCart && _deliveryBeyondMax) ...[
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.gold.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: AppTheme.gold.withOpacity(0.45)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.route_outlined,
                                  size: 18, color: AppTheme.gold),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _deliveryRefusal ??
                                      'Delivery is not available this far away.',
                                  style: const TextStyle(
                                      fontSize: 12.5, height: 1.45),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      // ── Next: the payment step, on its own screen ──
                      //
                      // The account to pay into, the amount the buyer writes
                      // down and the proof-of-payment upload live on
                      // /user/payment, which this button opens with the
                      // fulfillment choice already settled. That is the whole
                      // reason it is a separate screen: the buyer has just
                      // decided HOW the thing arrives, and the next thing they
                      // see should be where the money goes — not one more
                      // section at the bottom of a long form.
                      //
                      // A listing flagged requires_availability_confirmation
                      // behaves exactly as before: the order is placed first
                      // and paid later from the order screen once the provider
                      // has confirmed, so the payment screen shows this notice
                      // in place of the accounts rather than asking for money
                      // for something not yet confirmed.
                      if (_needsAvailabilityConfirmation) ...[
                        const AvailabilityNotice(),
                        const SizedBox(height: 16),
                      ],
                      const SizedBox(height: 8),
                      // What the buyer is about to pay, in one line, so the
                      // button is not a leap: the payment screen itemises it.
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _needsAvailabilityConfirmation
                                ? 'Next: ask the provider, then pay'
                                : 'Next: pay',
                            style: const TextStyle(
                                fontSize: 13, color: AppTheme.textSecondary),
                          ),
                          Text(
                            _needsAvailabilityConfirmation
                                ? '—'
                                : '${_payableTotal.toStringAsFixed(2)} '
                                    '${_items.isNotEmpty ? _items.first.currency : 'ETB'}',
                            style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.primaryGreen),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        // On a gated listing the press does not pay and does
                        // not claim the booking: it ASKS the provider. So the
                        // button says what it does — "check availability" —
                        // rather than "pay", which reads as a purchase the
                        // buyer has not made yet.
                        child: PrimaryButton(
                          label: _needsAvailabilityConfirmation
                              ? 'CHECK AVAILABILITY'
                              : 'CONTINUE TO PAYMENT',
                          onPressed: _continueToPayment,
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}
