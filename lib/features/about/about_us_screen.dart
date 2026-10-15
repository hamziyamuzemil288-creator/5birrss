import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';

/// What Aliob actually is, and how to reach a human.
///
/// WHY THIS SCREEN EXISTS
/// ----------------------
/// The profile's "About Aliob" row pushed `/terms` — the Terms & Privacy
/// Policy. So the one place a user goes to find out what the app is instead
/// showed them a legal document, and there was no About screen to reach at
/// all. This is that screen, and "About Aliob" now opens it.
///
/// Nothing was removed to make room: the Terms & Privacy Policy is still
/// reachable from signup, from the Help Chat deep links, and now also from
/// the row at the bottom of this screen, so it is *more* reachable than
/// before rather than less.
///
/// The contact details are the ones the Terms screen already publishes
/// (WhatsApp 0917686990, muktarbiya329@gmail.com). They are repeated here
/// rather than invented, because a "contact us" that names a channel nobody
/// monitors is worse than no contact at all.
class AboutUsScreen extends StatelessWidget {
  const AboutUsScreen({super.key});

  /// Kept as constants so the three surfaces that need them (this screen, the
  /// Terms screen and support copy) are one edit apart rather than four.
  static const supportWhatsApp = '0917686990';
  static const supportEmail = 'muktarbiya329@gmail.com';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About Aliob')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          children: [
            _hero(),
            const SizedBox(height: 24),
            _section(
              'What Aliob is',
              'Aliob is a location-based marketplace for Ethiopia. It brings the '
                  'shops you buy from, the professionals you hire and the vehicles '
                  'you travel in onto one platform, so a single account works '
                  'whether you are ordering goods, booking a service or asking '
                  'for a ride. Every trade is mediated by the platform: buyers '
                  'pay Aliob rather than a stranger, Aliob verifies the payment, '
                  'and only then are the two sides introduced. Nobody has to '
                  'chase a phone number or guess whether the other account can be '
                  'trusted.',
            ),
            const SizedBox(height: 20),
            _section(
              'Our mission',
              'To connect shops, service providers and vehicles in one '
                  'marketplace — so customers stop chasing phone numbers and '
                  'providers stop depending on who happens to know them. Every '
                  'trade is ranked on its own terms, priced by its own category, '
                  'paid through the platform, and settled through the provider\'s '
                  'wallet.',
            ),
            const SizedBox(height: 20),
            const Text(
              'Three kinds of provider, one account',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primaryGreenDark),
            ),
            const SizedBox(height: 10),
            _pillar(
              Icons.storefront_outlined,
              'Shops & listings',
              'Products with photos, stock and per-category commission. '
                  'Availability can be confirmed by the provider before you pay.',
            ),
            _pillar(
              Icons.handyman_outlined,
              'Service providers',
              'Trades that price their own work, with the documents, wallet '
                  'balance and subscription the platform requires before they '
                  'can take an order.',
            ),
            _pillar(
              Icons.directions_car_outlined,
              'Vehicles & rides',
              'Drivers and vehicles that appear on the live map, claim a ride '
                  'request and run the trip end to end.',
            ),
            const SizedBox(height: 20),
            _section(
              'How payments work',
              'Aliob handles the money itself. You pay into the payment account '
                  'the platform publishes inside the app, and upload a '
                  'screenshot of the transfer as proof. An administrator '
                  'verifies that proof, and only then are contact details '
                  'released so the two sides can complete the trade. The '
                  'platform\'s fee is taken from the provider\'s wallet when the '
                  'job is confirmed, and both sides are told every time money '
                  'moves. Because the platform, not the seller, receives the '
                  'payment, no provider has to publish a bank account for '
                  'buyers to pay into.',
            ),
            const SizedBox(height: 20),
            const Text(
              'Contact us',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primaryGreenDark),
            ),
            const SizedBox(height: 10),
            _contactRow(Icons.chat_outlined, 'WhatsApp', supportWhatsApp),
            _contactRow(Icons.mail_outline, 'Email', supportEmail),
            const SizedBox(height: 20),
            // The Terms & Privacy Policy stays one tap away from here, so
            // repointing "About" at this screen does not make it harder to
            // find than it was.
            // The Terms of Service and the policy that covers data are two
            // different documents, so they are two rows rather than one tile
            // that hides the Terms behind a policy title. Both are reachable
            // from here, and both are mirrored on the public policy site that
            // Play Console points at.
            Card(
              elevation: 0,
              color: AppTheme.surfaceVariant,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: AppTheme.cardBorder),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.description_outlined,
                        color: AppTheme.textSecondary),
                    title: const Text('Terms of Service',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                        'The rules every trade on Aliob is held to',
                        style: TextStyle(fontSize: 12)),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () => context.push('/terms-of-service'),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.gavel_outlined,
                        color: AppTheme.textSecondary),
                    title: const Text('Terms & Privacy Policy',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                        'How we handle your data and your rights',
                        style: TextStyle(fontSize: 12)),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    onTap: () => context.push('/terms'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Center(
              child: Text(
                'Aliob — all in one.',
                style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 1.2,
                    color: AppTheme.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hero() {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Container(
            width: 84,
            height: 84,
            color: AppTheme.primaryGreen,
            alignment: Alignment.center,
            child: Image.asset(
              'assets/images/aliob_logo_mark.png',
              width: 84,
              height: 84,
              // The mark is what the login screen shows. If the asset is ever
              // missing, fall back to a wordmark rather than a broken box.
              errorBuilder: (_, __, ___) => const Text(
                'A',
                style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textOnPrimary),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        const Text('Aliob',
            style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w700,
                letterSpacing: 3,
                color: AppTheme.textPrimary)),
        const SizedBox(height: 4),
        const Text('All in one',
            style: TextStyle(
                fontSize: 12.5,
                letterSpacing: 1.8,
                color: AppTheme.textSecondary)),
      ],
    );
  }

  Widget _section(String title, String body) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppTheme.primaryGreenDark)),
        const SizedBox(height: 6),
        Text(body,
            style: const TextStyle(
                fontSize: 13.5, height: 1.5, color: AppTheme.textPrimary)),
      ],
    );
  }

  Widget _pillar(IconData icon, String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppTheme.primaryGreen.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: AppTheme.primaryGreenDark),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(body,
                    style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: AppTheme.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _contactRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppTheme.primaryGreenDark),
          const SizedBox(width: 10),
          Text('$label: ',
              style: const TextStyle(
                  fontSize: 13, color: AppTheme.textSecondary)),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
