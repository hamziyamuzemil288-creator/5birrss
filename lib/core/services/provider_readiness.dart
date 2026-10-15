import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'provider_doc_gate.dart';
import '../theme/app_theme.dart';

/// What the SERVER says is outstanding before this provider may publish.
///
/// ## Why this exists instead of `ProviderDocGate`
///
/// `ProviderDocGate.isSatisfied()` is a **client-side, fail-open** gate and it
/// counts a document in `MANUAL_REVIEW` as accepted — on purpose, so that a
/// provider who has just uploaded an ID is not locked out of their own business
/// by an admin's review queue.
///
/// The server does not agree. `provider_documents_verified()` (migration 0113)
/// accepts only `AUTO_APPROVED` / `VERIFIED`, because before 0113 a document
/// satisfied the gate by *being uploaded*: `user_documents.verification_status`
/// DEFAULTS to `MANUAL_REVIEW` and a BEFORE INSERT trigger forces it, so
/// "verified" meant "queued".
///
/// Those two halves disagree, and the consequence is the reported bug: the
/// client gate says yes, so the provider fills in the entire listing form, and
/// the server — which is the one that matters — refuses at Save with a bare
/// `PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED`. Every field is a dead end
/// and nothing on the screen ever said so.
///
/// So anything the provider SEES must come from the server. This class asks
/// `provider_fulfilment_blockers()` — the same function the gate itself calls —
/// rather than re-deriving the rule on the client, where it could drift from
/// the server again. The one thing it must never do is decide on its own; the
/// server's answer is the answer, and a failure to ask is reported as "unknown"
/// rather than as "ready".
class ProviderReadiness {
  const ProviderReadiness({
    required this.reasons,
    required this.checked,
  });

  /// Server-side reason codes, e.g. `DOCUMENTS_UNVERIFIED`. Empty when the
  /// provider may publish.
  final List<String> reasons;

  /// False when the server could not be asked.
  ///
  /// Deliberately distinct from "ready". An unreachable server must not render
  /// a green "you can publish" — that is the same class of lie as the original
  /// bug, just in the other direction.
  final bool checked;

  /// The optimistic-but-honest reading: no known blockers.
  ///
  /// Only call this when [checked]; a provider who cannot be asked is not the
  /// same as a provider who has nothing outstanding, and the two need different
  /// words on screen.
  bool get isReady => checked && reasons.isEmpty;

  static const ProviderReadiness unknown =
      ProviderReadiness(reasons: [], checked: false);

  /// The human sentence for a reason code, and where the provider goes to fix
  /// it.
  ///
  /// The same vocabulary `provider_fulfilment_blockers()` emits and
  /// `friendly_error()` already translates, kept in one place so a reason can
  /// never be displayed one way in the banner and another way in the failure
  /// dialog. The destination is what turns "something is wrong" into "here is
  /// where you fix it" — without it the banner is just a scolding.
  ///
  /// `route` is null for DOCUMENTS_UNVERIFIED on purpose: document upload is a
  /// sheet, not a screen (`ProviderDocGate.ensureDocuments` opens a dialog),
  /// and there is no `/provider/documents` route to push. Inventing one to keep
  /// the table uniform would have produced a button that navigates nowhere —
  /// the same dead end this class exists to remove.
  static const Map<String, ({String phrase, String? route, String action})>
      remedies = {
    'DOCUMENTS_UNVERIFIED': (
      phrase: 'your ID has not been verified yet',
      route: null,
      action: 'Upload or check your ID',
    ),
    'ACTIVATION_FEE_UNPAID': (
      phrase: 'the one-time activation fee is unpaid',
      route: '/wallet',
      action: 'Pay the activation fee',
    ),
    'WALLET_EMPTY': (
      phrase: 'your wallet is empty, so the platform fee cannot be covered',
      route: '/wallet/recharge',
      action: 'Top up your wallet',
    ),
    'WALLET_BELOW_MINIMUM': (
      phrase: 'your wallet is below the minimum balance the platform requires '
          'before posting',
      route: '/wallet/recharge',
      action: 'Top up your wallet',
    ),
    'SUBSCRIPTION_UNPAID': (
      phrase: 'your subscription is unpaid, so your account is suspended',
      route: '/provider/subscription',
      action: 'Renew your subscription',
    ),
    'ACCOUNT_NOT_APPROVED': (
      phrase: 'your account has not been approved yet',
      route: '/provider/business',
      action: 'Check your business profile',
    ),
    'PROVIDER_NOT_FOUND': (
      phrase: 'that business no longer exists',
      route: '/provider/business',
      action: 'Open your business profile',
    ),
    // There is deliberately no 'NO_PAYMENT_ACCOUNT' remedy any more: the
    // server stopped raising it in 20261015000010 (the platform collects the
    // payment, so a provider has no account to add), and a remedy left behind
    // would send a provider to a screen that no longer accepts one — the
    // generic fallback below is the honest answer if a stale server ever does
    // send the code.
  };

  /// An unrecognised code still gets a sentence.
  ///
  /// A new reason added to `provider_fulfilment_blockers()` must not make the
  /// banner print a raw token to a provider — the banner is exactly the surface
  /// that exists so nobody has to read a machine code. So the fallback is
  /// generic, not empty, and it still points somewhere.
  static ({String phrase, String? route, String action}) remedyFor(
      String code) {
    return remedies[code] ??
        (
          phrase: 'your account setup is incomplete',
          route: '/provider/business',
          action: 'Open your business profile',
        );
  }

  /// Reads the server's answer. Never throws.
  ///
  /// A failed read is [ProviderReadiness.unknown], NOT "ready": the whole
  /// point of this class is that the app stops guessing where the server is
  /// allowed to publish.
  static Future<ProviderReadiness> load(String providerId) async {
    try {
      final res = await Supabase.instance.client.rpc(
        'provider_fulfilment_blockers',
        params: {'p_provider_id': providerId},
      );
      if (res is! List) return unknown;
      final reasons = res
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList();
      // The payment-account rule that used to be read here (and appended as
      // NO_PAYMENT_ACCOUNT) is gone from the server as of 20261015000010, and
      // with it the read: `provider_fulfilment_blockers()` is now the whole
      // answer, which is what this class was always meant to report.
      return ProviderReadiness(
        reasons: reasons,
        checked: true,
      );
    } catch (_) {
      return unknown;
    }
  }

  /// Whether a failed write was the gate refusing, rather than a real error.
  ///
  /// Both the reason-carrying code and the bare one are recognised, because a
  /// provider on an app build from before migration 0117 talks to whichever
  /// server the project is currently on. Getting this wrong in the other
  /// direction — treating a gate refusal as an ordinary failure — is what
  /// produced the original report, so the test is deliberately permissive and
  /// this is the ONLY place that decides which dialog to show.
  static bool isPublishRefusal(Object error) {
    final raw = error.toString().toLowerCase();
    return raw.contains('provider_not_fulfilment_ready') ||
        raw.contains('provider_not_activated_or_documents_required');
  }

  /// Pulls the reason codes out of a refusal.
  ///
  /// Returns an EMPTY list for the bare code, which is not a failure to parse:
  /// the server genuinely did not say, and inventing reasons would be worse
  /// than saying "open your business profile". [remedyFor] already returns a
  /// generic, actionable remedy for that case.
  static List<String> reasonsFromRefusal(String raw) {
    final match = RegExp(
      r'provider_not_fulfilment_ready\s*:\s*([A-Za-z_,\s]*)',
      caseSensitive: false,
    ).firstMatch(raw);
    if (match == null) return const [];
    return (match.group(1) ?? '')
        .split(RegExp(r'[,\s]+'))
        .map((s) => s.trim().toUpperCase())
        .where((s) => s.isNotEmpty)
        .toList();
  }
}

/// Shows the reasons a save was refused, each with the screen that fixes it.
///
/// Public so a widget test can drive the real dialog rather than a copy of its
/// layout — the overflow and overflow-safety regressions in this repo were all
/// found by testing the actual widget.
Future<void> showPublishBlockedDialog(BuildContext context, String raw) async {
  final reasons = ProviderReadiness.reasonsFromRefusal(raw);
  // The bare code carries no reasons; show the generic one rather than an empty
  // list, which would read as "something is wrong but not what".
  final display = reasons.isEmpty
      ? const ['ACCOUNT_NOT_APPROVED']
      : reasons;

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.lock_outline, color: AppTheme.warning, size: 30),
      title: const Text('Before you can publish'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Your listing was not saved. Finish this first — everything you '
            'typed is still on this form and will be waiting when you come '
            'back.',
            style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 14),
          for (final code in display) ...[
            Builder(builder: (innerContext) {
              final remedy = ProviderReadiness.remedyFor(code);
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 5, right: 8),
                          child: Icon(Icons.circle,
                              size: 6, color: AppTheme.textMuted),
                        ),
                        Expanded(
                          child: Text(
                            remedy.phrase,
                            style: const TextStyle(
                                fontSize: 14, color: AppTheme.textPrimary),
                          ),
                        ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () async {
                          Navigator.pop(innerContext);
                          // A null route is the document sheet; anything else
                          // is a screen. Sending a WALLET_EMPTY provider to
                          // the ID upload sheet instead of the recharge screen
                          // would be a new dead end in place of the old one.
                          if (remedy.route == null) {
                            await ProviderDocGate.instance
                                .ensureDocuments(context);
                          } else if (context.mounted) {
                            await context.push(remedy.route!);
                          }
                        },
                        icon: const Icon(Icons.arrow_forward, size: 16),
                        label: Text(remedy.action),
                        style: TextButton.styleFrom(
                          foregroundColor: AppTheme.primaryGreen,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
