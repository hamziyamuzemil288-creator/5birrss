import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/cart_service.dart';
import '../../core/services/document_upload_service.dart';
import '../../core/services/fee_resolver.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/utils/friendly_failure.dart';
import '../../core/utils/order_number_format.dart' as onf;
import '../../core/widgets/admin_payment_details_card.dart';
import '../../core/widgets/availability_notice.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';

/// What the checkout screen hands to the payment screen.
///
/// A plain value object rather than a second copy of the checkout's state: the
/// buyer has already chosen the fulfillment method, the delivery vehicle and
/// the delivery point by the time this is built, and everything the payment
/// step needs to DISPLAY is here. Nothing about the price is computed from it —
/// the order total is resolved by the server when the order is created — so a
/// stale draft can show a stale number but can never charge one.
class OrderDraft {
  const OrderDraft({
    required this.providerId,
    required this.providerName,
    required this.items,
    required this.fulfillmentMode,
    this.deliveryAddress = '',
    this.deliveryLat,
    this.deliveryLng,
    this.deliveryVehicleId,
    this.deliveryVehicleName,
    this.deliveryFee = 0,
    this.deliveryDistanceKm,
    this.paymentDeferred = false,
    this.commissionPreview,
  });

  final String providerId;
  final String providerName;
  final List<CartItem> items;

  /// 'DELIVERY' or 'SELF_PICKUP' — the two the server knows.
  final String fulfillmentMode;
  final String deliveryAddress;
  final double? deliveryLat;
  final double? deliveryLng;
  final String? deliveryVehicleId;
  final String? deliveryVehicleName;
  final double deliveryFee;
  final double? deliveryDistanceKm;

  /// True for a listing whose provider must confirm it is available first. The
  /// order is placed now and paid later from the order screen, exactly as the
  /// checkout behaved before the payment step became its own screen — the
  /// notice is shown instead of the accounts so the buyer is not asked to pay
  /// for something the provider has not confirmed.
  final bool paymentDeferred;

  /// The platform commission this order will incur, resolved by the same
  /// reader `deduct_transaction_fee` charges with. Display-only: the buyer
  /// never pays it.
  final FeeQuote? commissionPreview;

  bool get isDelivery => fulfillmentMode == 'DELIVERY';

  double get productTotal => items.fold<double>(0, (s, i) => s + i.lineTotal);

  double get deliveryFeeShown => isDelivery ? deliveryFee : 0;

  /// What the buyer is about to pay: the public product prices plus the
  /// delivery fee when there is one. Matches `orders.total_amount` for the
  /// part the client can know; the server is still the pricer.
  double get payableTotal => productTotal + deliveryFeeShown;

  String get currency => items.isNotEmpty ? items.first.currency : 'ETB';
}

/// THE PAYMENT STEP — its own screen, after the fulfillment choice is
/// confirmed.
///
/// The report this exists for: the account to pay into, the proof-of-payment
/// upload and the place to write down what was paid were spread through the
/// bottom of a long checkout screen, below the cart, the fulfillment picker
/// and (for delivery) the vehicle and map steps. A buyer who had just chosen
/// how they wanted the thing could not tell where the transaction actually
/// started.
///
/// So the flow is now two screens with one job each:
///
///   checkout   — the basket, and HOW it arrives (delivery vehicle + point, or
///                self-pickup). It ends at CONTINUE TO PAYMENT.
///   payment    — the platform account the administrator configured in
///                Admin → Payment Settings, the amount and reference the buyer
///                writes down, the proof-of-payment photo, and PLACE ORDER.
///
/// Everything that was wired before is still wired, only moved: the platform
/// account card, the payment reference, the screenshot upload into
/// `payment-proofs`, the National ID upload into `user-documents`, the
/// availability gate's deferred-payment notice, the provider-readiness
/// re-check with its waiting screen, and the same `order-create` call whose
/// server-computed total is what the order records.
///
/// And when something goes wrong, the appeal door is HERE, on the screen where
/// the money is, deep-linked straight into the admin Appeals queue that the
/// admin dashboard's badge counts.
class UserPaymentScreen extends ConsumerStatefulWidget {
  const UserPaymentScreen({super.key, required this.draft});

  /// Null only from a deep link or a restored route (the draft is not
  /// serialisable). Handled, not crashed: the screen sends the buyer back to
  /// their cart.
  final OrderDraft? draft;

  @override
  ConsumerState<UserPaymentScreen> createState() => _UserPaymentScreenState();
}

class _UserPaymentScreenState extends ConsumerState<UserPaymentScreen> {
  final _refCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  File? _screenshot;
  File? _nationalId;
  final _picker = ImagePicker();

  bool _loading = true;
  bool _submitting = false;
  bool _needsNationalId = true;
  String? _error;
  DateTime? _lastOrderTime;
  bool _amountPrefilled = false;

  /// The order this step created, once it exists. The appeal door hands it
  /// over so a case filed about THIS transaction names it in the admin queue
  /// instead of arriving as an untagged paragraph.
  String? _createdOrderId;

  /// The human-readable order number for the order this step created, when the
  /// row predates migration 0037's `order_number` column. Used by the appeal
  /// door to label which transaction the dispute is about.
  String? _createdOrderNumber;

  /// Provider readiness, re-checked on load and again at submission. A
  /// provider whose registration fee is unpaid, or whose wallet is empty, has
  /// the order refused by `create_order_secure` — the waiting screen exists so
  /// the buyer is told that rather than reading a server error.
  bool _providerActivated = true;
  bool _providerHasBalance = true;
  String _providerName = 'The provider';

  SupabaseClient get _client => Supabase.instance.client;

  OrderDraft? get _draft => widget.draft;

  @override
  void initState() {
    super.initState();
    final draft = _draft;
    if (draft != null) {
      _providerName = draft.providerName;
      // Pre-filled with the amount the screen shows, because the number a
      // buyer writes down is almost always the number they paid. Editable:
      // this records what they transferred, it does not set the charge.
      _amountCtrl.text = draft.payableTotal.toStringAsFixed(2);
      _amountPrefilled = true;
    }
    _load();
  }

  @override
  void dispose() {
    _refCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await _refreshProviderReadiness();
    // Whether this buyer still needs to give a National ID. Users sign up with
    // only email/phone/password, so the ID is verified at the first purchase —
    // read from user_documents, best-effort: a failure leaves the requirement
    // in place, which is always the safe direction.
    try {
      final uid = _client.auth.currentUser?.id;
      if (uid != null) {
        final existing = await _client
            .from('user_documents')
            .select('id')
            .eq('user_id', uid)
            .eq('document_type', 'NATIONAL_ID')
            .limit(1)
            .maybeSingle();
        if (existing != null) _needsNationalId = false;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _refreshProviderReadiness() async {
    final draft = _draft;
    if (draft == null) return;
    try {
      final prov = await _client
          .from('public_provider_profiles')
          .select('business_name, registration_fee_paid, status')
          .eq('id', draft.providerId)
          .maybeSingle();
      if (prov == null) return;
      _providerName = (prov['business_name'] as String?)?.isNotEmpty == true
          ? prov['business_name'] as String
          : _providerName;
      _providerActivated = (prov['registration_fee_paid'] as bool?) == true &&
          prov['status'] == 'APPROVED';
      final wallet = await _client
          .from('wallets')
          .select('balance')
          .eq('provider_id', draft.providerId)
          .maybeSingle();
      _providerHasBalance =
          ((wallet?['balance'] as num?)?.toDouble() ?? 0) > 0;
    } catch (_) {
      // Non-fatal: the server-side gate still refuses and the refusal is
      // surfaced after submission.
    }
  }

  Future<void> _pickScreenshot() async {
    // Downscaled like every other bucket upload in the app: payment-proofs
    // allows 10MB, which hides the problem on most phones but not on a 48MP
    // camera image.
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked != null && mounted) {
      setState(() => _screenshot = File(picked.path));
    }
  }

  Future<void> _pickNationalId() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked != null && mounted) {
      setState(() => _nationalId = File(picked.path));
    }
  }

  /// The appeal door. Every case an admin can act on lands in `appeal_cases`,
  /// which is exactly what the admin dashboard's Appeals card counts and
  /// `/admin/appeals` lists — so a buyer who hit a problem at the money step
  /// gets it in front of the team in two taps, pre-tagged as a dispute.
  ///
  /// The door hands the dispute over with the same text the order screen shows
  /// the buyer: the human-readable order number when the order predates migration
  /// 0037, otherwise the raw order id. That label is written into
  /// `appeal_cases.description` by the appeal form, and the admin queue and case
  /// sheet already render the description on every row, so the reviewer sees
  /// which transaction the dispute is about without asking anyone.
  void _openAppeal() {
    final ref = _createdOrderId;
    if (ref == null) {
      context.push('/appeal?about=dispute');
      return;
    }
    final id = ref;
    final label = _createdOrderNumber != null
        ? 'Order $_createdOrderNumber'
        : 'Transaction $id';
    context
        .push('/appeal?about=dispute&order=${Uri.encodeComponent(label)}');
  }

  Future<void> _placeOrder() async {
    final draft = _draft;
    if (draft == null) return;

    // Duplicate-tap guard: prevent double-submission within 3 seconds.
    final now = DateTime.now();
    if (_lastOrderTime != null &&
        now.difference(_lastOrderTime!) < const Duration(seconds: 3)) {
      return;
    }
    _lastOrderTime = now;

    if (draft.items.isEmpty) {
      setState(() => _error = 'Your cart is empty for this provider');
      return;
    }
    if (!draft.paymentDeferred && _needsNationalId && _nationalId == null) {
      setState(() => _error =
          'Please upload a photo of your National ID to place an order');
      return;
    }
    if (draft.isDelivery && draft.deliveryAddress.trim().isEmpty) {
      setState(() => _error =
          'A delivery order needs an address. Go back and add one.');
      return;
    }

    await _refreshProviderReadiness();
    if (mounted) setState(() {});
    if (!_providerActivated || !_providerHasBalance) {
      await context.push('/user/order-waiting', extra: {
        'providerId': draft.providerId,
        'providerName': _providerName,
        'providerNotActivated': !_providerActivated,
      });
      if (!mounted) return;
      await _refreshProviderReadiness();
      if (!mounted) return;
      if (!_providerActivated || !_providerHasBalance) return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    // Once order-create returns, the order EXISTS. Everything after that point
    // is bookkeeping and none of it may report failure — otherwise the buyer
    // is told their order failed, submits again, and creates a duplicate.
    String? createdOrderId;
    var orderCreated = false;
    try {
      final client = _client;

      final writtenAmount = _amountCtrl.text.trim();
      final noteParts = <String>[
        if (draft.fulfillmentMode == 'SELF_PICKUP') 'Fulfillment: self-pickup',
        if (draft.isDelivery && draft.deliveryAddress.trim().isNotEmpty)
          'Delivery: ${draft.deliveryAddress.trim()}',
        // The amount the buyer wrote down, and why it is only a record: the
        // order's total is computed by the server from the public prices.
        if (writtenAmount.isNotEmpty && !draft.paymentDeferred)
          'Amount written by buyer: $writtenAmount',
        if (draft.isDelivery && draft.deliveryFee > 0)
          'Delivery fee: ${draft.deliveryFee.toStringAsFixed(2)}'
              '${draft.deliveryVehicleName != null ? ' (${draft.deliveryVehicleName})' : ''}'
              '${draft.deliveryDistanceKm != null ? ', ${draft.deliveryDistanceKm} km' : ''}',
        if (_refCtrl.text.trim().isNotEmpty)
          'Payment ref: ${_refCtrl.text.trim()}',
      ];

      final result = await client.functions.invoke('order-create', body: {
        'provider_id': draft.providerId,
        'items': draft.items
            .map((i) => {'product_id': i.productId, 'quantity': i.quantity})
            .toList(),
        if (noteParts.isNotEmpty) 'note': noteParts.join(' | '),
        'fulfillment_mode': draft.fulfillmentMode,
        if (draft.isDelivery) 'delivery_address': draft.deliveryAddress.trim(),
        // The delivery PRICING INPUTS — coordinates and a vehicle category,
        // never a fee. The Edge Function resolves the provider's own point and
        // prices the trip with the same delivery quote the checkout showed.
        if (draft.isDelivery && draft.deliveryLat != null)
          'delivery_lat': draft.deliveryLat,
        if (draft.isDelivery && draft.deliveryLng != null)
          'delivery_lng': draft.deliveryLng,
        if (draft.isDelivery && draft.deliveryVehicleId != null)
          'vehicle_category_id': draft.deliveryVehicleId,
      });
      final data = Map<String, dynamic>.from(result.data as Map);
      final order = data['order'] as Map<String, dynamic>?;
      final orderId = order?['id'] as String?;
      createdOrderId = orderId;
      _createdOrderId = orderId;
      orderCreated = true;
      final orderNumber =
          onf.formatOrderNumber(order?['order_number'] as String?);
      if (orderNumber != null) {
        _createdOrderNumber = orderNumber;
      }

      // ID on file → uploaded with the same retry as signup. The order already
      // exists, so a failed upload is reported, never re-submitted.
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
              'uploaded. Open Profile → Verify Document (or Help & Support) to '
              'retry so your identity can be verified.';
        }
      }

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
              'Your order was placed, but the payment screenshot could not be '
              'attached.';
        }
      }

      // Only the lines that were actually ordered leave the cart.
      //
      // This used to clear the whole basket. That was harmless while an order
      // always meant "everything from this provider", but a buyer can now buy
      // one listing out of several, and emptying the cart would have silently
      // deleted the lines they deliberately did not buy. Removing by product id
      // is exactly the `removeFromCart` the cart screen itself uses.
      var cartIssue = false;
      try {
        for (final item in draft.items) {
          await CartService.instance.removeFromCart(item.productId);
        }
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
                  : 'Your order has been placed successfully. You can track it '
                      'in My Orders.'));
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
        // The order is real. Say so plainly and go to it rather than implying
        // it failed — the obvious next move after "failed" is to submit again.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(friendlyError(e,
                context:
                    'Your order was placed, but we could not finish the last step')),
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
        // exact to hand support instead of a screenshot of a sentence — and
        // the appeal door below is one tap away.
        _error = friendlyErrorWithRef(e,
            context: 'Could not place your order', source: 'payment');
      });
    }
  }

  static String _fmtQty(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final draft = _draft;

    if (draft == null || draft.items.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Payment')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.shopping_cart_outlined,
                    size: 56, color: AppTheme.textMuted),
                const SizedBox(height: 16),
                const Text(
                  'There is nothing to pay for yet. Your cart for this '
                  'provider is empty.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, height: 1.45),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () => context.go('/user/cart'),
                  child: const Text('GO TO CART'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Payment')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. What is being paid for, and how it arrives.
                  _summaryCard(draft),
                  const SizedBox(height: 20),

                  // 2. The account the administrator configured — the number
                  //    the buyer actually sends money to. Reused, not
                  //    reimplemented: the same card the admin's Payment
                  //    Settings feed and the order screen shows.
                  if (!draft.paymentDeferred) ...[
                    const Text('Pay to this account',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    const Text(
                      'Send the total below to this account, then write down '
                      'what you sent and attach the receipt.',
                      style: TextStyle(
                          fontSize: 12.5, height: 1.4, color: AppTheme.textMuted),
                    ),
                    const SizedBox(height: 10),
                    const AdminPaymentDetailsCard(),
                    const SizedBox(height: 20),

                    // 3. The price-writing section: the amount the buyer
                    //    actually sent, and the reference it carries. Neither
                    //    sets the charge — the server prices the order — but
                    //    both are what the admin verifies the payment against.
                    _amountCard(draft),
                    const SizedBox(height: 20),

                    // 4. The image upload.
                    _proofCard(),
                    const SizedBox(height: 8),
                    if (_needsNationalId) _nationalIdCard(),
                  ] else
                    // The same notice the checkout shows before CONTINUE TO
                    // PAYMENT is pressed — one definition, so the two screens
                    // cannot drift into saying different things about the same
                    // waiting state.
                    const AvailabilityNotice(),

                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.error.withOpacity(0.07),
                        borderRadius: BorderRadius.circular(10),
                        border:
                            Border.all(color: AppTheme.error.withOpacity(0.3)),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                            fontSize: 13, height: 1.4, color: AppTheme.error),
                      ),
                    ),
                  ],

                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: PrimaryButton(
                      // On a gated listing the press does not pay and does not
                      // claim the booking: it ASKS the provider. So the button
                      // says what it does.
                      label: draft.paymentDeferred
                          ? 'CHECK AVAILABILITY'
                          : 'PLACE ORDER',
                      isLoading: _submitting,
                      onPressed: _placeOrder,
                    ),
                  ),
                  const SizedBox(height: 20),

                  // 5. The way out when something went wrong. Not a help
                  //    article: a case, filed into `appeal_cases`, which is
                  //    what the admin dashboard's Appeals badge counts and
                  //    /admin/appeals lists.
                  _appealCard(),
                  const SizedBox(height: 12),
                ],
              ),
            ),
    );
  }

  Widget _summaryCard(OrderDraft draft) {
    return Container(
      width: double.infinity,
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
              Expanded(
                child: Text(_providerName,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700)),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.primaryGreen.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  draft.isDelivery
                      ? (draft.deliveryVehicleName == null
                          ? 'DELIVERY'
                          : 'DELIVERY · ${draft.deliveryVehicleName!.toUpperCase()}')
                      : 'SELF-PICKUP',
                  style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.primaryGreen),
                ),
              ),
            ],
          ),
          if (draft.isDelivery && draft.deliveryAddress.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              draft.deliveryAddress.trim(),
              style: const TextStyle(fontSize: 12.5, height: 1.35),
            ),
          ],
          const Divider(height: 22),
          for (final item in draft.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                      '${_fmtQty(item.quantity)} ${item.unit != null ? item.unitLabel : '×'} '
                      '${item.price.toStringAsFixed(2)}',
                      style: const TextStyle(
                          fontSize: 12.5, color: AppTheme.textSecondary)),
                  const SizedBox(width: 10),
                  Text(item.lineTotal.toStringAsFixed(2),
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          const Divider(height: 22),
          _row('Product price',
              '${draft.productTotal.toStringAsFixed(2)} ${draft.currency}'),
          if (draft.deliveryFeeShown > 0) ...[
            const SizedBox(height: 6),
            _row(
                draft.deliveryVehicleName == null
                    ? 'Delivery fee'
                    : 'Delivery fee (${draft.deliveryVehicleName})',
                '${draft.deliveryFeeShown.toStringAsFixed(2)} ${draft.currency}'),
          ],
          const Divider(height: 22),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Total to pay',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              Text(
                '${draft.payableTotal.toStringAsFixed(2)} ${draft.currency}',
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primaryGreen),
              ),
            ],
          ),
          if (draft.commissionPreview?.hasValue ?? false) ...[
            const SizedBox(height: 6),
            Text(
              'Platform commission on this order: '
              'ETB ${draft.commissionPreview!.value!.toStringAsFixed(2)} '
              '(deducted from the provider — no extra cost to you)',
              style: const TextStyle(
                  fontSize: 11.5,
                  height: 1.35,
                  color: AppTheme.textMuted),
            ),
          ],
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => context.pop(),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Change how it arrives',
                  style: TextStyle(fontSize: 12.5)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          Text(value, style: const TextStyle(fontSize: 13)),
        ],
      );

  /// The price-writing section: what the buyer sent, and the reference it
  /// carries. Both land on the order's note so the admin verifying the payment
  /// reads them next to the receipt.
  Widget _amountCard(OrderDraft draft) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.gold.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.gold.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Write down what you paid',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            'The order total is ${draft.payableTotal.toStringAsFixed(2)} '
            '${draft.currency}, computed by the platform. Write the amount you '
            'actually transferred so the admin can match it — this records '
            'what you sent, it does not change the total.',
            style: const TextStyle(
                fontSize: 12.5, height: 1.4, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 12),
          BirrTextField(
            label: 'Amount you paid (${draft.currency})',
            controller: _amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            hint: draft.payableTotal.toStringAsFixed(2),
          ),
          const SizedBox(height: 12),
          BirrTextField(
            label: 'Payment Reference (optional)',
            controller: _refCtrl,
            hint: 'Transaction ID or reference number',
          ),
          if (_amountPrefilled) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() {
                _amountCtrl.text = draft.payableTotal.toStringAsFixed(2);
              }),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Reset to the order total',
                  style: TextStyle(fontSize: 12.5)),
            ),
          ],
        ],
      ),
    );
  }

  /// The image upload option: proof of payment, into the same `payment-proofs`
  /// bucket and the same `payment_proofs` row the order screen uses.
  Widget _proofCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Proof of payment (optional)',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text(
          'Tap to upload the screenshot or photo of your transfer. The admin '
          'verifies your payment against it.',
          style: TextStyle(fontSize: 12.5, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: _pickScreenshot,
          child: Container(
            width: double.infinity,
            height: _screenshot != null ? 180 : 120,
            decoration: BoxDecoration(
              color: AppTheme.creamDark,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: _screenshot != null
                      ? AppTheme.primaryGreen
                      : AppTheme.cardBorder),
            ),
            child: _screenshot != null
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child:
                            Image.file(_screenshot!, fit: BoxFit.cover),
                      ),
                      Positioned(
                        right: 6,
                        top: 6,
                        child: Material(
                          color: Colors.black.withOpacity(0.55),
                          shape: const CircleBorder(),
                          child: IconButton(
                            iconSize: 18,
                            icon: const Icon(Icons.close, color: Colors.white),
                            onPressed: () =>
                                setState(() => _screenshot = null),
                          ),
                        ),
                      ),
                    ],
                  )
                : const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_a_photo_outlined,
                          size: 32, color: AppTheme.textMuted),
                      SizedBox(height: 8),
                      Text('Tap to upload proof of payment',
                          style: TextStyle(
                              fontSize: 13, color: AppTheme.textMuted)),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _nationalIdCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(
              child: Text('National ID (required)',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
            'First-time verification: we need a photo of your National ID to '
            'confirm your identity. It is stored securely and only visible to '
            'our admin team.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
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
                    child: Image.file(_nationalId!, fit: BoxFit.cover),
                  )
                : const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.badge_outlined,
                          size: 32, color: AppTheme.textMuted),
                      SizedBox(height: 8),
                      Text('Tap to upload your National ID',
                          style: TextStyle(
                              fontSize: 13, color: AppTheme.textMuted)),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

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
              'Something went wrong with this payment?',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: _openAppeal,
            child: const Text('REPORT IT',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
