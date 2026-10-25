import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers/auth_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/primary_button.dart';

/// Shown when the signed-in user's `profiles.status` is SUSPENDED or INACTIVE.
///
/// Why this screen exists
/// ----------------------
/// `account_status` has five values: PENDING_APPROVAL, APPROVED, REJECTED,
/// SUSPENDED, INACTIVE. The router gates the first three — pending users land
/// on /pending-approval, rejected on /rejected — but SUSPENDED and INACTIVE
/// matched none of those checks, so a suspended account fell through to a
/// fully working dashboard with no explanation at all.
///
/// That is not merely untidy. `suspend_provider` notifies the user
/// ("Account suspended") and the revenue scheduler sets provider status to
/// SUSPENDED automatically when a subscription fee cannot be paid, so
/// suspension is reachable without the user doing anything. Someone whose
/// subscription lapsed would open the app, find a normal dashboard, and have
/// no idea why nothing works.
///
/// Server-side enforcement already covers the actions that matter —
/// `suspend_provider` marks vehicles unavailable, and
/// `prevent_inactive_provider_publish` blocks a non-APPROVED provider from
/// publishing listings. This screen closes the gap in what the user is told,
/// not in what the database permits.
///
/// Distinct from `provider_subscription_screen`, which shows the
/// *subscription* lifecycle (ACTIVE -> DUE -> GRACE -> SUSPENDED). This is
/// the account-level status that the router keys off.
class SuspendedScreen extends ConsumerWidget {
  const SuspendedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const _SuspendedView();
  }
}

class _SuspendedView extends ConsumerStatefulWidget {
  const _SuspendedView();

  @override
  ConsumerState<_SuspendedView> createState() => _SuspendedViewState();
}

class _SuspendedViewState extends ConsumerState<_SuspendedView> {
  bool _sendingTicket = false;

  /// True when an administrator DELETED the business rather than suspending it
  /// (provider_profiles.deleted_at, 20261025000002). The two states share
  /// SUSPENDED because the enum has no DELETED member, but telling somebody
  /// "your subscription likely lapsed" when their business was removed would
  /// send them to recharge a wallet for a business that no longer exists.
  bool _removed = false;

  @override
  void initState() {
    super.initState();
    _checkRemoved();
  }

  Future<void> _checkRemoved() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      final row = await Supabase.instance.client
          .from('provider_profiles')
          .select('deleted_at')
          .eq('user_id', uid)
          .maybeSingle();
      if (mounted && row != null && row['deleted_at'] != null) {
        setState(() => _removed = true);
      }
    } catch (_) {
      // Best effort: the generic suspension copy still renders.
    }
  }

  /// Files a support_tickets row, which the admin panel already lists. Same
  /// mechanism the rejected screen uses, so there is one queue for "this
  /// account needs a human" rather than two.
  Future<void> _contactSupport() async {
    setState(() => _sendingTicket = true);
    try {
      final auth = ref.read(authProvider);
      final email = auth.user?.email ?? 'unknown';
      final status = auth.profile?.status ?? 'SUSPENDED';
      await Supabase.instance.client.from('support_tickets').insert({
        'subject': 'Suspended account — please review',
        'description':
            'My account has been suspended (status: $status). '
            'Account email: $email. Please let me know what is needed to '
            'restore my access.',
        'source': 'OTHER',
        // status defaults to OPEN, which the insert security trigger requires.
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Support request sent — our team will reach out to you.'),
        ),
      );
      await ref.read(authProvider.notifier).refreshProfile();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendlyError(e, context: 'Could not send your request'))),
      );
    } finally {
      if (mounted) setState(() => _sendingTicket = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final status = auth.profile?.status ?? 'SUSPENDED';
    final inactive = status == 'INACTIVE';

    return PopScope(
      // There is nowhere to go back to: every other route redirects here.
      canPop: false,
      child: Scaffold(
        body: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: inactive
                  ? [AppTheme.textSecondary, AppTheme.cream]
                  : [AppTheme.error, AppTheme.cream],
              stops: const [0.0, 0.4],
            ),
          ),
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Column(
                children: [
                  const SizedBox(height: 32),
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.pause_circle_filled,
                        color: Colors.white, size: 40),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _removed
                        ? 'Business account removed'
                        : (inactive
                            ? 'Account Deactivated'
                            : 'Account Suspended'),
                    style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        height: 1.25,
                        color: Colors.white),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _removed
                        ? 'An administrator removed this business from Aliob. '
                            'Your past orders and receipts are unaffected.'
                        : (inactive
                            ? 'This account is no longer active.'
                            : 'Your access to Aliob is currently paused.'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: Colors.white.withOpacity(0.85)),
                  ),
                  const SizedBox(height: 32),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.08),
                          blurRadius: 20,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        _infoRow(
                          Icons.pause_circle_outline,
                          'What this means',
                          'You cannot list services, take orders or drive '
                              'rides while the account is suspended.',
                        ),
                        const SizedBox(height: 16),
                        _infoRow(
                          Icons.credit_card_off_outlined,
                          'Common cause',
                          'A monthly subscription payment that could not be '
                              'completed. Recharging your wallet usually '
                              'resolves it.',
                        ),
                        const SizedBox(height: 16),
                        _infoRow(
                          Icons.support_agent,
                          'Need help?',
                          'Send our team a request and we will tell you '
                              'exactly what is needed to restore access.',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.error.withOpacity(0.2)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline,
                            color: AppTheme.error, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Status: ${status.replaceAll('_', ' ')}',
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: AppTheme.textPrimary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  PrimaryButton(
                    label: 'CONTACT SUPPORT',
                    icon: Icons.support_agent,
                    isLoading: _sendingTicket,
                    onPressed:
                        _sendingTicket ? null : () => _contactSupport(),
                  ),
                  const SizedBox(height: 12),
                  // Recharge first: a lapsed subscription is the usual cause
                  // and fixing it is entirely in the user's hands.
                  SizedBox(
                    width: double.infinity,
                    child: PrimaryButton(
                      label: 'RECHARGE WALLET',
                      isOutlined: true,
                      icon: Icons.account_balance_wallet_outlined,
                      // Wallet reads are RLS-scoped to the owner and stay
                      // available while suspended; only publishing and
                      // fulfilment are blocked server-side.
                      onPressed: () => context.push('/wallet/recharge'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  PrimaryButton(
                    label: 'REFRESH STATUS',
                    isOutlined: true,
                    icon: Icons.refresh,
                    onPressed: () =>
                        ref.read(authProvider.notifier).refreshProfile(),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: PrimaryButton(
                      label: 'LOGOUT',
                      onPressed: () => ref.read(authProvider.notifier).signOut(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String title, String desc) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppTheme.error.withOpacity(0.08),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: AppTheme.error, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 2),
              Text(desc,
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary)),
            ],
          ),
        ),
      ],
    );
  }
}
