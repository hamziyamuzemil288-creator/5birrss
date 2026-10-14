import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/platform_settings_service.dart';
import '../theme/app_theme.dart';

/// Where a BUYER pays: the PLATFORM's account, never a provider's.
///
/// Part 4 of the rework. Checkout used to show the provider's saved bank /
/// Telebirr / CBE Birr accounts through `provider_payment_accounts` — which
/// is exactly the direct provider-to-buyer money channel the rework closes.
/// The card now reads the administrator's configured details
/// (`system_settings.admin_payment_details`, edited in Admin → Payment
/// Settings, read through the whitelisted `public_app_settings()` RPC), and
/// falls back to the platform's Payment Methods rows (the same
/// admin-managed table the order screen already shows) when no details are
/// configured yet. A configuration outage is NEVER shown as "nowhere to
/// pay": with nothing configured the card says the team will contact the
/// buyer — the same sentence the order screen has always used.
///
/// The buyer still uploads their payment screenshot exactly as before; only
/// whose account they pay changed. The provider's wallet — how providers
/// eventually receive their earnings — is untouched.
class AdminPaymentDetailsCard extends StatefulWidget {
  const AdminPaymentDetailsCard({super.key});

  @override
  State<AdminPaymentDetailsCard> createState() =>
      _AdminPaymentDetailsCardState();
}

class _AdminPaymentDetailsCardState extends State<AdminPaymentDetailsCard> {
  String? _details;
  List<Map<String, dynamic>> _methods = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String? details;
    try {
      details = await PlatformSettings.paymentDetails();
    } catch (_) {
      details = null;
    }
    var methods = const <Map<String, dynamic>>[];
    if (details == null || details.trim().isEmpty) {
      try {
        final rows = await Supabase.instance.client
            .from('payment_methods')
            .select('name, account_name, account_number, instructions')
            .eq('is_active', true)
            .order('sort_order');
        methods = List<Map<String, dynamic>>.from(rows as List);
      } catch (_) {
        methods = const [];
      }
    }
    if (!mounted) return;
    setState(() {
      _details = (details == null || details.trim().isEmpty) ? null : details;
      _methods = methods;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.primaryGreen.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primaryGreen.withOpacity(0.3)),
      ),
      child: _loading
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.account_balance_outlined,
                        size: 18, color: AppTheme.primaryGreen),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('Where to pay — Aliob platform account',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary)),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (_details != null)
                  Text(
                    _details!,
                    style: const TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary),
                  )
                else if (_methods.isEmpty)
                  const Text(
                    'No payment account is available right now. Our team will '
                    'contact you with the details.',
                    style: TextStyle(
                        fontSize: 12.5, color: AppTheme.textSecondary),
                  )
                else
                  for (final m in _methods)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${m['name'] ?? 'Payment'}'
                            '${(m['account_name'] as String?)?.isNotEmpty == true ? ' — ${m['account_name']}' : ''}',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700),
                          ),
                          if ((m['account_number'] as String?)?.isNotEmpty ==
                              true)
                            Text(
                              m['account_number'] as String,
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.primaryGreen,
                                  letterSpacing: 0.4),
                            ),
                          if ((m['instructions'] as String?)?.isNotEmpty ==
                              true)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(m['instructions'] as String,
                                  style: const TextStyle(
                                      fontSize: 11.5,
                                      color: AppTheme.textMuted)),
                            ),
                        ],
                      ),
                    ),
                const SizedBox(height: 4),
                const Text(
                  'Pay into the account above, then upload your payment '
                  'screenshot. Money moves only after our team verifies it.',
                  style: TextStyle(
                      fontSize: 11.5, height: 1.4, color: AppTheme.textMuted),
                ),
              ],
            ),
    );
  }
}
