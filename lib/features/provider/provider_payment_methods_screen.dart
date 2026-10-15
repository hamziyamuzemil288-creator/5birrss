import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/payment_methods_service.dart';
import '../../core/services/wallet_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/primary_button.dart';

class ProviderPaymentMethodsScreen extends ConsumerStatefulWidget {
  const ProviderPaymentMethodsScreen({super.key});

  @override
  ConsumerState<ProviderPaymentMethodsScreen> createState() =>
      _ProviderPaymentMethodsScreenState();
}

class _ProviderPaymentMethodsScreenState
    extends ConsumerState<ProviderPaymentMethodsScreen> {
  /// Part 13: the provider's OWN account-number flow is gone from this screen
  /// — its controllers, its form key, its bank list and its account rows with
  /// it. All buyer payments go to the payment account the platform publishes,
  /// so there is no account of the provider's for a buyer to pay into. What
  /// remains is the wallet: the balance, the funding requests and the top-up
  /// flow that an administrator approves.
  List<Map<String, dynamic>> _walletFundingRequests = [];
  Map<String, dynamic>? _wallet;

  /// The PLATFORM's payment accounts (payment_methods, administrator-managed),
  /// which is where a provider's wallet top-up is sent. This screen used to
  /// offer the provider's OWN accounts here instead; since Part 13 the platform
  /// collects every payment, so the accounts a provider pays into are the
  /// platform's, and the same list the buyer's own recharge screen uses.
  List<Map<String, dynamic>> _platformMethods = [];
  String? _businessName;
  bool _loading = true;
  /// The local refusal sentence for the funding request (an amount the form
  /// refused, a failed submit). Kept separate from [_loadError], which is
  /// about the whole screen failing to load.
  String? _error;
  String? _loadError;
  bool _refreshing = false;

  /// `provider_profiles.id` — NOT the auth user id. Resolved by [_load].
  String? _providerId;

  @override
  void initState() {
    super.initState();
    // Nothing used to start this screen. `_loading` begins true, only
    // `_load()` ever clears it, and no path called `_load()` until a save had
    // already happened — so the screen sat on its spinner forever. A provider
    // could reach "Payment account number" from the dashboard, from the
    // posting checklist and from the readiness banner, and never once see the
    // form or the Add button behind it.
    _load();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _loadError = null;
    });
    try {
      // WHICH provider this screen belongs to, resolved before anything is
      // read or written. `provider_payment_methods.provider_id` is a foreign
      // key onto `provider_profiles(id)` (20260927000142) and every policy on
      // the table is `owns_provider_profile(provider_id)`, which matches on
      // `user_id = auth.uid()` — so the auth uid is not a provider id. Sending
      // it selected no rows (the screen read as empty however many accounts the
      // business had) and inserted a `provider_id` naming no profile at all, so
      // Add failed on the foreign key.
      final providerId = await _resolveProviderId();
      if (!mounted) return;
      if (providerId == null) {
        setState(() {
          _loading = false;
          _loadError = 'No business profile is linked to this account yet. '
              'Finish your provider registration, then come back to top up '
              'your wallet.';
        });
        return;
      }
      _providerId = providerId;

      // Every read is bounded (PaymentMethodsService.kTimeout, and the
      // .timeout below for the wallet reads): the endless spinner this
      // screen used to show was an un-awaited read that never returned —
      // no deadline meant no error state, no code and no retry.
      final platformMethods =
          await PaymentMethodsService.instance.getActiveMethods();
      final wallet = await WalletService.instance.getWallet(providerId)
          .timeout(PaymentMethodsService.kTimeout);
      final requests =
          await WalletService.instance.getMyWalletFundingSummary()
              .timeout(PaymentMethodsService.kTimeout);
      final requestsWithUrls = <Map<String, dynamic>>[];
      for (final r in requests) {
        final path = r['screenshot_storage_path'] as String?;
        if (path == null || path.isEmpty) {
          requestsWithUrls.add(r);
          continue;
        }
        try {
          final url = await WalletService.instance.getScreenshotUrl(path)
              .timeout(PaymentMethodsService.kTimeout);
          requestsWithUrls.add(Map<String, dynamic>.from(r)
            ..['_screenshotUrl'] = url);
        } catch (_) {
          requestsWithUrls.add(Map<String, dynamic>.from(r)
            ..['_screenshotUrl'] = null);
        }
      }
      String? name;
      if (wallet != null) {
        try {
          final client = Supabase.instance.client;
          final prov = await client
              .from('provider_profiles')
              .select('business_name')
              .eq('id', providerId)
              .maybeSingle()
              .timeout(PaymentMethodsService.kTimeout);
          name = prov?['business_name'] as String?;
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _wallet = wallet;
          _platformMethods = platformMethods;
          _walletFundingRequests = requestsWithUrls;
          _businessName = name;
          _loading = false;
          _loadError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError =
              friendlyError(e, context: 'Could not load payment accounts');
        });
      }
    }
  }

  /// `provider_profiles.id` for the signed-in account, or null when the
  /// account has no business profile (a buyer, or a provider whose signup row
  /// has gone).
  ///
  /// Read as a list rather than `.maybeSingle()`: one person can hold more
  /// than one provider profile (a business and a driver), and `maybeSingle()`
  /// throws on two rows. A service business is preferred, because this screen
  /// is opened from the service-provider dashboard; failing that, whichever
  /// profile the account has.
  Future<String?> _resolveProviderId() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return null;
    final rows = await Supabase.instance.client
        .from('provider_profiles')
        .select('id, provider_type')
        .eq('user_id', userId)
        .timeout(PaymentMethodsService.kTimeout);
    final mine = List<Map<String, dynamic>>.from(rows as List);
    if (mine.isEmpty) return null;
    for (final r in mine) {
      if (r['provider_type'] == 'SERVICE_PROVIDER') return r['id'] as String;
    }
    return mine.first['id'] as String;
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      await _load();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _showAddFundsSheet() async {
    final amountCtrl = TextEditingController();
    final refCtrl = TextEditingController();
    File? screenshot;
    String? selectedMethodId;
    final picker = ImagePicker();

    void pickScreenshot() async {
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (picked != null) {
        setState(() => screenshot = File(picked.path));
      }
    }

    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Add funds from a payment account',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                const Text(
                  'This request will be reviewed by an admin before it is '
                  'credited to your wallet. It cannot be approved by you.',
                  style: TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: selectedMethodId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Pay to (the platform account)',
                    isDense: true,
                  ),
                  // The platform's accounts, not the provider's own: the money
                  // is collected by Aliob and credited to this wallet once an
                  // administrator confirms it.
                  items: _platformMethods
                      .map((m) => DropdownMenuItem<String>(
                            value: m['id'] as String,
                            child: Text(m['name'] ?? ''),
                          ))
                      .toList(),
                  onChanged: (v) => setSheet(() => selectedMethodId = v),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: amountCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Amount (ETB)',
                    prefixText: 'ETB ',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: refCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Reference (optional)',
                    hintText: 'Transaction ID or note',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
                GestureDetector(
                  onTap: pickScreenshot,
                  child: Container(
                    width: double.infinity,
                    height: screenshot != null ? 160 : 100,
                    decoration: BoxDecoration(
                      color: AppTheme.creamDark,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.cardBorder),
                    ),
                    child: screenshot != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              screenshot!,
                              fit: BoxFit.cover,
                            ),
                          )
                        : const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                  Icons.add_a_photo_outlined,
                                  size: 28,
                                  color: AppTheme.textMuted),
                              SizedBox(height: 8),
                              Text(
                                'Add a payment screenshot (optional)',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.textMuted,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: PrimaryButton(
                    label: 'Submit for review',
                    onPressed: () async {
                      Navigator.of(sheet).pop(true);
                      await _submitProviderWalletFunding(
                        selectedMethodId: selectedMethodId,
                        amountCtrl: amountCtrl,
                        refCtrl: refCtrl,
                        screenshot: screenshot,
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.of(sheet).pop(false),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submitProviderWalletFunding({
    required String? selectedMethodId,
    required TextEditingController amountCtrl,
    required TextEditingController refCtrl,
    required File? screenshot,
  }) async {
    final providerId = _providerId;
    if (providerId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No business profile is linked to this account yet, '
                'so there is no wallet to fund.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }
    final amount = double.tryParse(amountCtrl.text);
    if (selectedMethodId == null || selectedMethodId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Choose a payment account'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }
    if (amount == null || amount <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Enter a valid amount'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    setState(() {
      _error = null;
    });

    String? screenshotPath;
    if (screenshot != null) {
      try {
        screenshotPath = await WalletService.instance.uploadScreenshot(
          screenshot.path,
          providerId,
        );
      } on Exception catch (e) {
        if (mounted) {
          setState(() {
            _error = friendlyError(
                e, context: 'Could not upload your payment screenshot');
          });
          // The sentence is SHOWN, not just stored: a refusal recorded in a
          // field nothing renders is a refusal the provider never sees, and
          // they go on believing the request went through.
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_error!),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
    }

    try {
      await WalletService.instance.submitProviderWalletFundingRequest(
        providerId: providerId,
        walletId: (_wallet?['id'] as String?) ?? '',
        paymentMethodId: selectedMethodId,
        amount: amount,
        paymentReference: refCtrl.text.trim().isEmpty
            ? null
            : refCtrl.text.trim(),
        screenshotStoragePath: screenshotPath,
      );
      if (mounted) {
        _load();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Funding request submitted. An admin will credit it when approved.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error =
              friendlyError(e, context: 'Could not submit your funding request');
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_error!),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _walletBalanceCard() {
    final wallet = _wallet;
    final hasWallet = wallet != null && (wallet['id'] as String?)?.isNotEmpty == true;
    final balance = hasWallet ? (wallet['balance'] as num?)?.toDouble() ?? 0 : 0.0;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.primaryGreen, AppTheme.primaryGreenDark],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _businessName ?? '',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      balance.toStringAsFixed(2),
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const Text(
                      'ETB available in your wallet',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white60,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.account_balance_wallet,
                color: Colors.white,
                size: 36,
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (hasWallet)
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: 'Add funds from a payment account',
                icon: Icons.add,
                onPressed: _showAddFundsSheet,
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                'No wallet yet. Contact support to set one up so you can fund it from your payment accounts.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  color: Colors.white,
                ),
              ),
            ),
          const SizedBox(height: 12),
          const Text(
            'Your wallet is funded by you through this screen. The amount you '
            'enter is reviewed by an admin before it is credited.',
            style: TextStyle(
              fontSize: 11.5,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pendingRequestsCard() {
    if (_walletFundingRequests.isEmpty && !_refreshing) {
      return const SizedBox.shrink();
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.hourglass_empty,
                    size: 18, color: AppTheme.warning),
                const SizedBox(width: 8),
                const Text(
                  'Awaiting admin review',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  '${_walletFundingRequests.length} request'
                  '${_walletFundingRequests.length == 1 ? '' : 's'}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'These funding requests are reviewed by an admin. You will be '
              'notified when one is approved or rejected.',
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.textMuted,
              ),
            ),
            const SizedBox(height: 12),
            if (_refreshing)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(
                      color: AppTheme.primaryGreen),
                ),
              )
            else
              ...(_walletFundingRequests.map((r) {
                final amount =
                    (r['amount'] as num?)?.toStringAsFixed(2) ?? '0.00';
                final status = (r['status'] as String?) ?? 'PENDING';
                final when = r['created_at'] != null
                    ? DateTime.tryParse(r['created_at'] as String)
                    : null;
                final screenshotUrl =
                    r['_screenshotUrl'] as String?;
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: AppTheme.cardBorder,
                      width: 0.5,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '$amount ETB',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.warning.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              status,
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.warning,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              (r['payment_methods'] as Map<String, dynamic>?)
                                      ?['name'] as String?
                                  ?? 'Payment account',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ),
                          if (when != null)
                            Text(
                              '${when.day}/${when.month}/${when.year}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.textMuted,
                              ),
                            ),
                        ],
                      ),
                      if (screenshotUrl != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              screenshotUrl,
                              height: 90,
                              width: 120,
                              fit: BoxFit.cover,
                              loadingBuilder: (
                                BuildContext context,
                                Widget? child,
                                ImageChunkEvent? progress,
                              ) {
                                return child ?? const SizedBox.shrink();
                              },
                              errorBuilder: (
                                BuildContext context,
                                Object exception,
                                StackTrace? stackTrace,
                              ) {
                                return const SizedBox.shrink();
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              })),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet & payments'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                  color: AppTheme.primaryGreen))
          : _loadError != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                          Icons.error_outline,
                          size: 64,
                          color: AppTheme.textMuted),
                      const SizedBox(height: 16),
                      Text(
                        _loadError!,
                        style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 14),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              : _body(context),
    );
  }

  Widget _body(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _walletBalanceCard(),
          if (_walletFundingRequests.isNotEmpty) _pendingRequestsCard(),
        ],
      ),
    );
  }

}
