import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/location_service.dart';
import '../services/platform_settings_service.dart';
import '../theme/app_theme.dart';

/// Contact Aliob support — the PLATFORM's number, never a provider's.
///
/// Part 3 of the rework. Every customer-facing "talk to a human" door now
/// routes to the platform: the number is `system_settings.admin_contact_phone`,
/// edited in Admin → Contact Settings and read through the whitelisted
/// `public_app_settings()` RPC (migration 20261014000003). Nothing here — or
/// in any screen that embeds this card — hard-codes a phone number, and no
/// provider's number is ever a candidate: a provider's contact is escrow
/// (released by `release_order_contact` only after payment is verified) and
/// lives on the order's own contact card.
///
/// Fallbacks are stated, not guessed:
///   * no number configured  → the in-app help chat (/help), so an
///     unconfigured setting reads as "chat with us", never as "nowhere";
///   * the settings read fails → the same help chat (PlatformSettings
///     swallows the outage and returns the empty map).
class PlatformContactCard extends StatefulWidget {
  const PlatformContactCard({super.key});

  @override
  State<PlatformContactCard> createState() => _PlatformContactCardState();
}

class _PlatformContactCardState extends State<PlatformContactCard> {
  String? _phone;
  bool _loading = true;
  bool _calling = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    String? phone;
    try {
      phone = await PlatformSettings.contactPhone();
    } catch (_) {
      phone = null;
    }
    if (!mounted) return;
    setState(() {
      _phone = phone;
      _loading = false;
    });
  }

  Future<void> _call() async {
    final phone = _phone;
    if (phone == null || _calling) return;
    setState(() => _calling = true);
    // Best-effort: a device with no dialer (or a web build without a phone
    // handler) gets the in-app chat instead of a silent dead tap.
    final opened = await LocationService.instance.openPhoneCall(phone);
    if (!mounted) return;
    setState(() => _calling = false);
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Could not open the dialer — use the help chat to reach us.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.teal.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.teal.withOpacity(0.35)),
      ),
      child: _loading
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(4),
                child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.support_agent_outlined,
                        size: 18, color: AppTheme.teal),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text('Need help? Contact Aliob support',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_phone != null) ...[
                  Text(
                    _phone!,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.teal,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Our team handles payments, orders and accounts — '
                    'providers never see this number.',
                    style:
                        TextStyle(fontSize: 11.5, height: 1.4, color: AppTheme.textMuted),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _calling ? null : _call,
                      icon: const Icon(Icons.call_outlined, size: 18),
                      label: const Text('CALL SUPPORT'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.teal,
                        side: BorderSide(color: AppTheme.teal.withOpacity(0.5)),
                      ),
                    ),
                  ),
                ] else ...[
                  const Text(
                    'Our team is one message away — help is always available '
                    'inside the app.',
                    style:
                        TextStyle(fontSize: 12.5, height: 1.45, color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => context.push('/help'),
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      label: const Text('OPEN HELP CHAT'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.teal,
                        side: BorderSide(color: AppTheme.teal.withOpacity(0.5)),
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
