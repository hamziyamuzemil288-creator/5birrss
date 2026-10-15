import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/app_theme.dart';
import 'fee_resolver.dart';
import 'provider_doc_gate.dart';
import 'provider_readiness.dart';

/// The state of one of the three things a provider must finish before they
/// may post a listing: document verification, the wallet minimum, and an
/// active payment account (item 6).
enum PostingStepState {
  /// This step is satisfied — by the server's own answer, never by a guess.
  done,

  /// Nothing has been done yet, and a button below takes them to it.
  todo,

  /// Uploaded, waiting for an administrator. Not "done", but not something
  /// the provider can act on either — so it never hides the other step.
  underReview,

  /// Declined; a new document is needed. The reason travels with it.
  rejected,

  /// The verification agent flagged the document. Needs a human.
  flagged,

  /// We could not read this step. Shown as unknown, never as done.
  unknown,
}

/// One checklist row: what it is, where it stands, and where the button goes.
class PostingStep {
  const PostingStep({
    required this.code,
    required this.title,
    required this.detail,
    required this.state,
    this.actionLabel,
    this.route,
    this.opensSheet = false,
  });

  /// The server's reason code (`DOCUMENTS_UNVERIFIED`, `WALLET_EMPTY`, ...).
  final String code;
  final String title;
  final String detail;
  final PostingStepState state;

  /// Null when the row has nothing to offer (a step that is done, or one
  /// that is under review and therefore not the provider's to fix).
  final String? actionLabel;

  /// Where the action goes. Null means "a sheet, not a screen" — the
  /// document upload is a dialog, and inventing a route for it would produce
  /// a button that navigates nowhere.
  final String? route;
  final bool opensSheet;

  bool get isDone => state == PostingStepState.done;
}

/// What the gate knows about one provider, right now.
///
/// [checked] is false when the SERVER could not be asked, which is a
/// different answer from "nothing is outstanding": a provider who cannot be
/// reached must never see a green checklist. Everything else in this class
/// is display; the readiness rule itself is the server's array of blockers.
class PostingGateState {
  const PostingGateState({
    required this.checked,
    required this.blockers,
    required this.documents,
    required this.wallet,
    required this.balance,
    required this.requiredAmount,
    required this.verificationRequired,
    this.activationFee,
    this.listingFee,
  });

  /// False when `provider_fulfilment_blockers()` could not be reached.
  final bool checked;

  /// The server's reason codes. Empty = may post.
  final List<String> blockers;

  final PostingStep documents;
  final PostingStep wallet;

  /// The provider's wallet balance as read just now (0 when unreadable).
  final double balance;

  /// The admin-configured minimum the wallet must hold to post.
  final double requiredAmount;

  /// Whether the admin currently requires verified documents at all.
  final bool verificationRequired;

  /// Item H: the one-time activation fee, resolved by the SAME reader the
  /// charge withholds with (`fee_activation`). Null when the reader was
  /// unreachable — the row then shows "unavailable", never 0.
  final FeeQuote? activationFee;

  /// Item H: the product listing fee, resolved by `fee_product_listing_fee`.
  /// Null when unreachable.
  final FeeQuote? listingFee;

  static const PostingGateState unknown = PostingGateState(
    checked: false,
    blockers: [],
    documents: PostingStep(
      code: 'DOCUMENTS_UNVERIFIED',
      title: 'Document verification',
      detail: 'We could not check your verification status.',
      state: PostingStepState.unknown,
    ),
    wallet: PostingStep(
      code: 'WALLET_EMPTY',
      title: 'Wallet recharge',
      detail: 'We could not check your wallet balance.',
      state: PostingStepState.unknown,
    ),
    balance: 0,
    requiredAmount: 0,
    verificationRequired: true,
  );

  /// The two steps the checklist walks a provider through. It was three until
  /// 20261015000010 removed the payment-account step: the platform collects the
  /// payment, so there is no account for a provider to publish and nothing to
  /// count here. Leaving the third step in would show every provider a step
  /// they can no longer complete anywhere in the app.
  static const int totalSteps = 2;

  int get doneCount =>
      (documents.isDone ? 1 : 0) + (wallet.isDone ? 1 : 0);

  /// "1 of 2 done" — the progress line above the checklist.
  String get progressLabel => '$doneCount of $totalSteps done';

  double get progress => doneCount / totalSteps;

  /// The server's answer, and the only one that decides whether the button
  /// proceeds to the form. Only a definite "no" blocks: an unreadable
  /// document or wallet step is shown as unknown, never as done, and the
  /// create path still enforces the server's rules.
  bool get ready => checked && blockers.isEmpty;

  /// Blockers the two named steps do not already cover (account not
  /// approved, unpaid activation fee, suspended subscription). They are
  /// rendered under the checklist so nothing is silently swallowed.
  List<String> get extraBlockers => blockers
      .where((b) => b != 'DOCUMENTS_UNVERIFIED' && !b.startsWith('WALLET'))
      .toList();

  /// True when the wallet is the only thing outstanding.
  bool get onlyWalletLeft => !wallet.isDone && documents.isDone;

  /// Build the display state from the raw inputs. Pure, so a test can drive
  /// every branch without a database.
  factory PostingGateState.from({
    required bool checked,
    required List<String> blockers,
    required DocReviewState docState,
    required double balance,
    required double requiredAmount,
    required bool verificationRequired,
    String? rejectionReason,
    FeeQuote? activationFee,
    FeeQuote? listingFee,
  }) {
    final docsBlocked = blockers.contains('DOCUMENTS_UNVERIFIED');
    final walletBlockers =
        blockers.where((b) => b.startsWith('WALLET')).toList();

    return PostingGateState(
      checked: checked,
      blockers: blockers,
      documents: _documentStep(
        docState: docState,
        blocked: docsBlocked,
        verificationRequired: verificationRequired,
        rejectionReason: rejectionReason,
      ),
      wallet: _walletStep(
        blocked: walletBlockers.isNotEmpty,
        balance: balance,
        requiredAmount: requiredAmount,
        unreadable: balance < 0,
      ),
      balance: balance,
      requiredAmount: requiredAmount,
      verificationRequired: verificationRequired,
      activationFee: activationFee,
      listingFee: listingFee,
    );
  }

  static PostingStep _documentStep({
    required DocReviewState docState,
    required bool blocked,
    required bool verificationRequired,
    String? rejectionReason,
  }) {
    const todo = PostingStep(
      code: 'DOCUMENTS_UNVERIFIED',
      title: 'Document verification',
      detail: 'Upload a photo of your ID — a one-time check.',
      state: PostingStepState.todo,
      actionLabel: 'Verify identity',
      opensSheet: true,
    );

    switch (docState) {
      case DocReviewState.verified:
        return const PostingStep(
          code: 'DOCUMENTS_UNVERIFIED',
          title: 'Document verification',
          detail: 'Your ID is verified.',
          state: PostingStepState.done,
        );
      case DocReviewState.pending:
        return PostingStep(
          code: 'DOCUMENTS_UNVERIFIED',
          title: 'Document verification',
          // Under review is not done — but it is also not something the
          // provider can push forward, so it never blocks the OTHER step
          // from being finished while they wait.
          detail: blocked
              ? 'Under review — our team is checking it. This step needs '
                  'nothing from you right now.'
              : 'Under review — our team is checking it.',
          state: PostingStepState.underReview,
        );
      case DocReviewState.rejected:
        return PostingStep(
          code: 'DOCUMENTS_UNVERIFIED',
          title: 'Document verification',
          detail: rejectionReason == null || rejectionReason.trim().isEmpty
              ? 'Your document was declined. Upload a new one to continue.'
              : 'Declined: ${rejectionReason.trim()} Upload a new one to '
                  'continue.',
          state: PostingStepState.rejected,
          actionLabel: 'Upload a new ID',
          opensSheet: true,
        );
      case DocReviewState.flagged:
        return const PostingStep(
          code: 'DOCUMENTS_UNVERIFIED',
          title: 'Document verification',
          detail: 'This document needs a manual review. Please contact '
              'support.',
          state: PostingStepState.flagged,
        );
      case DocReviewState.none:
      case DocReviewState.unknown:
        if (!verificationRequired && !blocked) {
          return const PostingStep(
            code: 'DOCUMENTS_UNVERIFIED',
            title: 'Document verification',
            detail: 'Not required by the platform right now.',
            state: PostingStepState.done,
          );
        }
        return todo;
    }
  }

  static PostingStep _walletStep({
    required bool blocked,
    required double balance,
    required double requiredAmount,
    required bool unreadable,
  }) {
    final amount = requiredAmount > 0
        ? '${_fmtMoney(requiredAmount)} ETB minimum'
        : 'a positive balance';
    if (unreadable) {
      return PostingStep(
        code: 'WALLET_EMPTY',
        title: 'Wallet recharge',
        detail:
            'We could not read your balance — pull to refresh and try again.',
        state: PostingStepState.unknown,
        actionLabel: 'Open wallet',
        route: '/wallet/recharge',
      );
    }
    if (!blocked) {
      return PostingStep(
        code: 'WALLET_EMPTY',
        title: 'Wallet recharge',
        detail: requiredAmount > 0
            ? '${_fmtMoney(balance)} ETB — meets the $amount.'
            : '${_fmtMoney(balance)} ETB on file.',
        state: PostingStepState.done,
      );
    }
    final short = requiredAmount - balance;
    return PostingStep(
      code: 'WALLET_EMPTY',
      title: 'Wallet recharge',
      detail: '${_fmtMoney(balance)} ETB on file — ${_fmtMoney(short)} ETB '
          'short of the $amount.',
      state: PostingStepState.todo,
      actionLabel: 'Recharge wallet',
      route: '/wallet/recharge',
    );
  }

  static String _fmtMoney(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
}

/// Enforces the two-step posting gate — document verification and the
/// admin-configured wallet minimum — at both of the places a listing is
/// started from: the header's "+ Post product" button and the add-product
/// form's Save.
///
/// ## Why this is a second gate when `ProviderDocGate` exists
///
/// `ProviderDocGate` is a client-side, fail-open sheet that exists so a
/// provider is never locked out of uploading an ID. It cannot answer "may
/// this provider post a listing", because that question belongs to the
/// server: `provider_fulfilment_blockers()` (migration 0113, extended by
/// 20261006000002) is the only authority, and the product insert refuses
/// without it. So this class READS that function and turns its codes into a
/// checklist with somewhere to go — it never decides readiness itself.
class PostingGate {
  PostingGate._();
  static final PostingGate instance = PostingGate._();

  SupabaseClient get _client => Supabase.instance.client;

  /// The current state. Never throws: an unreachable server comes back as
  /// [PostingGateState.unknown], which is not ready and says why.
  Future<PostingGateState> check(String providerId) async {
    final userId = _client.auth.currentUser?.id;

    // 1. The server's blockers — the answer that decides everything.
    var checked = false;
    var blockers = const <String>[];
    try {
      final res = await _client.rpc(
        'provider_fulfilment_blockers',
        params: {'p_provider_id': providerId},
      );
      if (res is List) {
        blockers = res
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
        checked = true;
      }
    } catch (e) {
      debugPrint('PostingGate.check(blockers) failed: ${e.runtimeType}');
    }

    // 2. How far the document actually got — display only, and the reason
    //    the prompt can say "under review" instead of "not verified".
    var docState = DocReviewState.unknown;
    String? rejectionReason;
    try {
      docState = await ProviderDocGate.instance.reviewState(userId: userId);
      if (docState == DocReviewState.rejected) {
        rejectionReason = await _rejectionReason(userId);
      }
    } catch (_) {}

    // 3. The admin's knobs: is verification required, and how much wallet
    //    is enough. Both live in system_settings so the answer cannot
    //    drift between the app and the server. "Enough" is
    //    GREATEST(posting_min_wallet_balance, posting_fee) — the same
    //    GREATEST provider_fulfilment_blockers() enforces (migration
    //    20261006000003) — so the number on the checklist row is the number
    //    the server will actually require.
    var verificationRequired = true;
    var minWallet = 0.0;
    var postingFee = 0.0;
    try {
      final rows = await _client
          .from('system_settings')
          .select('key, value')
          .inFilter('key', [
        'enforce_verified_documents',
        'posting_min_wallet_balance',
        'posting_fee',
      ]);
      for (final raw in rows as List) {
        final row = Map<String, dynamic>.from(raw as Map);
        if (row['key'] == 'enforce_verified_documents') {
          verificationRequired = row['value'] == true || row['value'] == 'true';
        } else if (row['key'] == 'posting_min_wallet_balance') {
          minWallet = (row['value'] as num?)?.toDouble() ?? 0;
        } else if (row['key'] == 'posting_fee') {
          postingFee = (row['value'] as num?)?.toDouble() ?? 0;
        }
      }
    } catch (_) {
      // The settings table is unreadable: keep the server's own verdict as
      // the source for "is verification required", inferred below.
      verificationRequired = blockers.contains('DOCUMENTS_UNVERIFIED');
    }
    final requiredAmount = minWallet > postingFee ? minWallet : postingFee;

    // 4. The balance itself, for the numbers on the row. Negative marks
    //    "unreadable" so the row never prints a made-up 0.00 as fact.
    var balance = -1.0;
    try {
      final row = await _client
          .from('wallets')
          .select('balance')
          .eq('provider_id', providerId)
          .maybeSingle();
      balance = (row?['balance'] as num?)?.toDouble() ?? 0;
    } catch (_) {}

    // 6. Item H: the two provider-side fees this path touches, resolved by the
    //    SAME readers the charge uses. Best-effort like every other read here.
    FeeQuote? activationFee;
    FeeQuote? listingFee;
    try {
      final preview = await _feePreview(providerId);
      activationFee = preview.activation;
      listingFee = preview.listing;
    } catch (_) {}

    return PostingGateState.from(
      checked: checked,
      blockers: blockers,
      docState: docState,
      balance: balance,
      requiredAmount: requiredAmount,
      verificationRequired: verificationRequired,
      rejectionReason: rejectionReason,
      activationFee: activationFee,
      listingFee: listingFee,
    );
  }

  /// The administrator's note on a declined document, if there is one.
  Future<String?> _rejectionReason(String? userId) async {
    if (userId == null) return null;
    try {
      final rows = await _client
          .from('user_documents')
          .select('agent_verdict')
          .eq('user_id', userId)
          .eq('verification_status', 'REJECTED');
      for (final raw in rows as List) {
        final verdict = (raw as Map)['agent_verdict'];
        if (verdict is Map && verdict['admin_note'] is String) {
          final note = (verdict['admin_note'] as String).trim();
          if (note.isNotEmpty) return note;
        }
      }
    } catch (_) {
      // A database without the column still gets the generic message.
    }
    return null;
  }

  /// Check, and prompt when there is something to do.
  ///
  /// Returns true when the caller may proceed to the add-product form. The
  /// prompt keeps re-checking itself (realtime + app resume), so a provider
  /// who recharges in the other tab — or whose ID gets approved while the
  /// prompt is open — is let through with no manual action at all.
  ///
  /// [andContinue] runs after the prompt closes in the ready state; it is
  /// the navigation to the form, and passing it is what makes "auto-allowed"
  /// mean "already on the form" rather than "button turned green".
  /// Re-entrancy guard for the singleton.
  ///
  /// [check] awaits several RPCs before the dialog is on screen, so a second
  /// tap on the entry button during that gap starts a second [ensure] and
  /// would stack a second checklist on the first — the double-tap edge case
  /// the gate exists to absorb. One prompt at a time: while a gate is in
  /// flight or its dialog is still open, further taps do nothing.
  bool _ensuring = false;

  Future<bool> ensure(
    BuildContext context, {
    required String providerId,
    Future<void> Function()? andContinue,
  }) async {
    if (_ensuring) return false;
    _ensuring = true;
    try {
      final state = await check(providerId);
      if (!context.mounted) return false;
      if (state.ready) return true;

      final proceed = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (_) => PostingChecklistDialog(
          providerId: providerId,
          initial: state,
          andContinue: andContinue,
        ),
      );
      return proceed == true;
    } finally {
      // Every exit path releases the guard — ready, blocked, dialog closed,
      // or an unexpected throw — so one failed prompt can never wedge the
      // button shut.
      _ensuring = false;
    }
  }
}

/// The prompt itself: three checklist steps, a progress line, and a button
/// per missing step that goes to the screen (or sheet) that fixes it.
///
/// Public so a widget test can drive the real dialog rather than a copy of
/// its layout — the overflow regressions in this repo were all found by
/// testing the actual widget.
class PostingChecklistDialog extends StatefulWidget {
  const PostingChecklistDialog({
    super.key,
    required this.providerId,
    required this.initial,
    this.andContinue,
  });

  final String providerId;
  final PostingGateState initial;
  final Future<void> Function()? andContinue;

  @override
  State<PostingChecklistDialog> createState() => _PostingChecklistDialogState();
}

class _PostingChecklistDialogState extends State<PostingChecklistDialog>
    with WidgetsBindingObserver {
  late PostingGateState _state = widget.initial;
  bool _checking = false;
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscribe();
    // The prompt always opens on a fresh answer: the caller's read may be a
    // moment old by the time the dialog is on screen.
    _recheck();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      unawaited(channel.unsubscribe());
    }
    super.dispose();
  }

  /// Watch the two tables whose changes can turn a "no" into a "yes": the
  /// document row an administrator approves, and the wallet row a recharge
  /// credits. No filter — a filter the server rejects is worse than none
  /// (see FeedBinding), and both tables are already scoped to the caller.
  void _subscribe() {
    try {
      final client = Supabase.instance.client;
      RealtimeChannel channel =
          client.channel('posting-gate-${DateTime.now().microsecondsSinceEpoch}');
      channel = channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'user_documents',
        callback: (_) => _recheck(),
      );
      channel = channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'wallets',
        callback: (_) => _recheck(),
      );
      channel = channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'provider_profiles',
        callback: (_) => _recheck(),
      );
      _channel = channel;
      // subscribe() returns the channel, not a future — it is the callback
      // form that is async, and this dialog re-reads on its own anyway.
      channel.subscribe();
    } catch (e) {
      // A device with no realtime still gets the resume and action rechecks.
      debugPrint('PostingChecklistDialog subscribe failed: ${e.runtimeType}');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning to the app is one of the two moments the spec asks for: the
    // provider may have approved the ID or the recharge may have landed in
    // another app.
    if (state == AppLifecycleState.resumed) _recheck();
  }

  Future<void> _recheck() async {
    if (_checking || !mounted) return;
    _checking = true;
    try {
      final next = await PostingGate.instance.check(widget.providerId);
      if (!mounted) return;
      setState(() => _state = next);
      if (next.ready) await _proceed();
    } finally {
      _checking = false;
    }
  }

  /// The gate cleared while the prompt was open: close it and go straight to
  /// the form, so "you are all set" never costs a manual action.
  Future<void> _proceed() async {
    if (!mounted) return;
    final cont = widget.andContinue;
    Navigator.of(context).pop(true);
    if (cont != null) {
      await cont();
    }
  }

  Future<void> _runAction(PostingStep step) async {
    if (!mounted) return;
    if (step.opensSheet) {
      await ProviderDocGate.instance.ensureDocuments(context);
    } else if (step.route != null) {
      await context.push(step.route!);
    }
    // Whatever they did — uploaded, recharged, cancelled — re-read the
    // server before repainting, so the row can never lag behind the truth.
    await _recheck();
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    return AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          const Icon(Icons.checklist_rounded,
              color: AppTheme.primaryGreen, size: 24),
          const SizedBox(width: 8),
          Expanded(child: Text(s.ready ? 'You are all set' : 'Before you post')),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Progress: "1 of 2 done" plus the bar that makes it legible at
          // a glance. Both steps are always named, even when they are done,
          // so the provider can see what the second thing is.
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: s.checked ? s.progress : null,
                    minHeight: 6,
                    color: AppTheme.primaryGreen,
                    backgroundColor: AppTheme.creamDark,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                s.progressLabel,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _StepRow(step: s.documents, onTap: () => _runAction(s.documents)),
          const SizedBox(height: 10),
          _StepRow(step: s.wallet, onTap: () => _runAction(s.wallet)),
          // The payment-account row that stood here was removed with the rule
          // itself (20261015000010): the platform collects the payment, so
          // there is no account for a provider to add and no step to walk.
          // Item H: the fees this path touches, shown inline. Each number comes
          // from the SAME resolver the charge calls (activation from
          // fee_activation, listing from fee_product_listing_fee), so the
          // provider is never quoted one fee and charged another.
          if (s.activationFee != null || s.listingFee != null) ...[
            const SizedBox(height: 14),
            _FeePreviewBlock(
              activation: s.activationFee,
              listing: s.listingFee,
            ),
          ],
          if (s.extraBlockers.isNotEmpty) ...[
            const SizedBox(height: 14),
            for (final code in s.extraBlockers) ...[
              Builder(builder: (inner) {
                final remedy = ProviderReadiness.remedyFor(code);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        remedy.phrase[0].toUpperCase() +
                            remedy.phrase.substring(1),
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.textPrimary),
                      ),
                      if (remedy.route != null)
                        TextButton.icon(
                          onPressed: () async {
                            await context.push(remedy.route!);
                            if (mounted) await _recheck();
                          },
                          icon: const Icon(Icons.arrow_forward, size: 15),
                          label: Text(remedy.action),
                          style: TextButton.styleFrom(
                            foregroundColor: AppTheme.primaryGreen,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                          ),
                        ),
                    ],
                  ),
                );
              }),
            ],
          ],
          if (!s.checked)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                'We could not reach the server to confirm your status. '
                'Nothing here changed — try again in a moment.',
                style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Close'),
        ),
        FilledButton(
          // Enabled only when the server agrees, and the double-tap guard is
          // the same flag the realtime recheck uses: two fast taps must not
          // push the form twice.
          onPressed: s.ready && !_checking ? _proceed : null,
          style: FilledButton.styleFrom(backgroundColor: AppTheme.primaryGreen),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

/// Item H: the inline fee preview. Two provider-side fees, each labelled with
/// the reader that answered it, so a number with no live resolver behind it is
/// shown as "unavailable" rather than as a confident zero.
class _FeePreviewBlock extends StatelessWidget {
  const _FeePreviewBlock({this.activation, this.listing});

  final FeeQuote? activation;
  final FeeQuote? listing;

  String _row(String label, FeeQuote? quote) {
    if (quote == null || !quote.hasValue) {
      return '$label: unavailable';
    }
    final v = quote.value!;
    final n = v == v.roundToDouble()
        ? v.toStringAsFixed(0)
        : v.toStringAsFixed(2);
    return '$label: ETB $n';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.creamDark,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.receipt_long_rounded,
                  size: 18, color: AppTheme.primaryGreen),
              SizedBox(width: 8),
              Text(
                'What posting costs',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _row('One-time activation fee', activation),
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: AppTheme.textSecondary,
            ),
          ),
          Text(
            _row('Product listing fee', listing),
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Quoted by the same readers the charge uses, so this is the number '
            'you are charged.',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.35,
              color: AppTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// One checklist row: status icon, title, the sentence that says where it
/// stands, and the button that fixes it.
class _StepRow extends StatelessWidget {
  const _StepRow({required this.step, required this.onTap});

  final PostingStep step;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (step.state) {
      PostingStepState.done => (Icons.check_circle_rounded, AppTheme.primaryGreen),
      PostingStepState.underReview =>
        (Icons.hourglass_top_rounded, AppTheme.gold),
      PostingStepState.rejected => (Icons.cancel_rounded, AppTheme.error),
      PostingStepState.flagged => (Icons.gpp_maybe_outlined, AppTheme.warning),
      PostingStepState.unknown => (Icons.help_outline_rounded, AppTheme.textMuted),
      PostingStepState.todo => (Icons.radio_button_unchecked, AppTheme.textMuted),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.creamDark,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  step.title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              if (step.isDone)
                const Text(
                  'Done',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primaryGreen,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            step.detail,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.35,
              color: AppTheme.textSecondary,
            ),
          ),
          if (step.actionLabel != null) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: onTap,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen.withOpacity(0.12),
                  foregroundColor: AppTheme.primaryGreenDark,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                child: Text(step.actionLabel!),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Item H: the two provider-side fees this path touches, resolved through the
/// shared [FeeResolver] so the numbers shown are the numbers charged — the
/// one-time activation fee (`fee_activation`, the reader
/// approve_wallet_recharge withholds with) and the product listing fee
/// (`fee_product_listing_fee`). Both resolve against the provider's own
/// category and city (`provider_fee_context`), the same context the charge
/// reads, so the preview and the charge cannot disagree about which fee
/// applies. Best-effort like every other read in the gate: an unreachable
/// reader comes back as a quote with no value, and the row says
/// "unavailable" instead of inventing a zero.
Future<({FeeQuote activation, FeeQuote listing})> _feePreview(
    String providerId) async {
  final ctx = await FeeResolver.instance.providerContext(providerId);
  final activation = await FeeResolver.instance.activationFee(
    categoryId: ctx.categoryId,
    city: ctx.city,
  );
  final listing = await FeeResolver.instance.listingFee(
    categoryId: ctx.categoryId,
    city: ctx.city,
  );
  return (activation: activation, listing: listing);
}
