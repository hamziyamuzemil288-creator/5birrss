import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';

/// Admin → Contact Settings / Payment Settings (Parts 3 and 4).
///
/// One screen, two sections, two doors into it, because the two settings are
/// the same idea: what a BUYER is told about reaching the platform and paying
/// it, configured as data instead of hard-coded in a screen. Every
/// customer-facing contact point routes to the number set here, and the
/// checkout payment card shows the details set here — never a provider's
/// phone number or bank account.
///
/// The storage is `system_settings` (keys `admin_contact_phone` and
/// `admin_payment_details`), the write path is the existing admin-gated,
/// type-checked, audited `admin_update_setting()` RPC, and the buyer-side
/// read is the whitelisted `public_app_settings()` RPC (migration
/// 20261014000003) — this screen is the only place the values are edited.
class AdminPlatformSettingsScreen extends StatefulWidget {
  /// Which section to focus first: 'contact' (default) or 'payment'.
  final String initialSection;

  const AdminPlatformSettingsScreen({
    super.key,
    this.initialSection = 'contact',
  });

  @override
  State<AdminPlatformSettingsScreen> createState() =>
      _AdminPlatformSettingsScreenState();
}

class _AdminPlatformSettingsScreenState
    extends State<AdminPlatformSettingsScreen> {
  static const _contactKey = 'admin_contact_phone';
  static const _paymentKey = 'admin_payment_details';

  final _contactCtrl = TextEditingController();
  final _paymentCtrl = TextEditingController();
  bool _loading = true;
  bool _savingContact = false;
  bool _savingPayment = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _contactCtrl.dispose();
    _paymentCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final rows = await Supabase.instance.client
          .from('system_settings')
          .select('key, value')
          .inFilter('key', const [_contactKey, _paymentKey]);
      for (final row in rows as List) {
        final map = Map<String, dynamic>.from(row as Map);
        final value = switch (map['value']) {
          final String s => s,
          final Map m => (m['v'] ?? m['value'] ?? '').toString(),
          _ => (map['value'] ?? '').toString(),
        };
        if (map['key'] == _contactKey) _contactCtrl.text = value;
        if (map['key'] == _paymentKey) _paymentCtrl.text = value;
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load the settings');
      });
    }
  }

  Future<void> _save(String key, TextEditingController ctrl,
      {required bool isPayment}) async {
    final value = ctrl.text.trim();
    setState(() {
      if (isPayment) {
        _savingPayment = true;
      } else {
        _savingContact = true;
      }
    });
    try {
      await Supabase.instance.client.rpc('admin_update_setting', params: {
        'p_key': key,
        'p_value': value,
        'p_description': isPayment
            ? 'Where buyers pay the platform (shown on checkout). One entry '
                'per line, e.g. "CBE Birr: 1000123456789".'
            : 'The support number buyers see instead of a provider\'s number.',
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Saved $key'),
        backgroundColor: AppTheme.success,
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(friendlyError(e, context: 'Could not save this setting')),
        backgroundColor: AppTheme.error,
      ));
    } finally {
      if (mounted) {
        setState(() {
          _savingContact = false;
          _savingPayment = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final focusPayment = widget.initialSection == 'payment';
    return Scaffold(
      appBar: AppBar(
          title: Text(focusPayment ? 'Payment Settings' : 'Contact Settings')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        ElevatedButton(
                            onPressed: () {
                              setState(() => _loading = true);
                              _load();
                            },
                            child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // ── Contact ──────────────────────────────────────────
                    const Text('Buyer support number',
                        style: AppTheme.sectionHeader),
                    const SizedBox(height: 6),
                    const Text(
                      'Every customer-facing "Contact support" card shows '
                      'THIS number — in place of any provider\'s phone '
                      'number, which buyers never see.',
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: AppTheme.textSecondary),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _contactCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone number',
                        hintText: 'e.g. 0911000000',
                        prefixIcon: Icon(Icons.support_agent_outlined),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _savingContact
                            ? null
                            : () => _save(_contactKey, _contactCtrl,
                                isPayment: false),
                        icon: _savingContact
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2))
                            : const Icon(Icons.save_outlined),
                        label: const Text('Save contact number'),
                      ),
                    ),
                    const Divider(height: 32),
                    // ── Payment ──────────────────────────────────────────
                    const Text('Platform payment account',
                        style: AppTheme.sectionHeader),
                    const SizedBox(height: 6),
                    const Text(
                      'Checkout shows THESE details to buyers — one entry '
                      'per line, e.g. "CBE Birr: 1000123456789" or '
                      '"Telebirr: 0911000000". Buyers still upload their '
                      'payment screenshot exactly as before; the provider\'s '
                      'own accounts are never shown to them.',
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: AppTheme.textSecondary),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _paymentCtrl,
                      maxLines: 5,
                      decoration: const InputDecoration(
                        labelText: 'Bank / mobile money details',
                        hintText: 'CBE Birr: 1000123456789\nTelebirr: 0911000000',
                        alignLabelWithHint: true,
                        prefixIcon: Icon(Icons.account_balance_outlined),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _savingPayment
                            ? null
                            : () => _save(_paymentKey, _paymentCtrl,
                                isPayment: true),
                        icon: _savingPayment
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2))
                            : const Icon(Icons.save_outlined),
                        label: const Text('Save payment details'),
                      ),
                    ),
                  ],
                ),
    );
  }
}
