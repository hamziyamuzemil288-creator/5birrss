import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/app_theme.dart';
import '../utils/friendly_error.dart';
import 'document_upload_service.dart';

/// Tri-state result of a document check.
///
/// The distinction exists because the old bool-only API made two very
/// different situations look identical to the UI — "you are verified" and
/// "we could not check" both returned true, and the caller's only possible
/// reaction was to do nothing. That silence is what made the "Verify your
/// account" button look dead.
enum DocCheckStatus {
  /// An accepted document is on file.
  satisfied,

  /// No accepted document yet — the upload flow should open.
  required,

  /// The check itself failed (network, RLS, missing table). Distinct from
  /// [satisfied]: we do not actually know.
  checkFailed,
}

/// What the user should be told about their identity check.
///
/// WHY THIS IS NOT [DocCheckStatus]
/// ------------------------------
/// [DocCheckStatus] answers a GATING question — "may this person work?" — and
/// it answers it generously on purpose: a document that is merely queued for
/// review must not lock a provider out of their own business, so MANUAL_REVIEW
/// satisfies it. That generosity is correct for gating and completely wrong for
/// display.
///
/// Reusing it for the profile tile is what produced the reported bug: the tile
/// read `satisfied` for a freshly uploaded, never-looked-at ID and rendered a
/// green "Identity verified" chip. There was not even an admin decision to
/// display — `user_documents.verification_status` had no VERIFIED/REJECTED
/// value until migration 20260927000030 added them.
///
/// Gating must keep using [DocCheckStatus]. Anything that SHOWS a state must
/// use this.
enum DocReviewState {
  /// No accepted identity document on file.
  none,

  /// A document is on file and nobody has looked at it yet.
  pending,

  /// Verified — automatically by the QR agent, or by an administrator.
  verified,

  /// An administrator refused it; a new document is needed.
  rejected,

  /// The verification agent flagged it as suspected fraud.
  flagged,

  /// The check itself failed. We do not know.
  unknown,
}

/// Document-verification gate (Task 7 item 3): providers no longer upload
/// documents at signup. Instead the FIRST protected action — uploading a
/// product/vehicle, or claiming/accepting an order — requires the docs.
/// By then the provider has recharged their wallet (the activation gate
/// already sits on the same screens), matching the intended business flow:
/// signup → recharge → documents → sell.
class ProviderDocGate {
  ProviderDocGate._();
  static final ProviderDocGate instance = ProviderDocGate._();

  SupabaseClient get _client => Supabase.instance.client;

  /// True when the signed-in provider has at least one accepted identity
  /// document (Task 9: the provider CHOOSES the type at upload time —
  /// National ID / Driving License / Passport — so the gate accepts any one
  /// of those types). Everything except SUSPECTED_FRAUD counts:
  /// AUTO_APPROVED (QR agent) and MANUAL_REVIEW (queued for admin) both
  /// satisfy the gate — a document awaiting review must not block the
  /// provider from working.
  static const acceptedDocTypes = <String, String>{
    'NATIONAL_ID': 'National ID',
    'DRIVING_LICENSE': 'Driving License',
    'PASSPORT': 'Passport',
  };

  /// The fourth choice in the upload sheet: a document outside the fixed
  /// three, named by the uploader in free text (business licence, kebele ID,
  /// health certificate, ...).
  ///
  /// Deliberately NOT a member of [acceptedDocTypes]: that map is what the
  /// GATE iterates, and an OTHER document must not satisfy identity
  /// verification merely by existing — only the four identity types do,
  /// and provider_docs_satisfied() excludes OTHER server-side for the same
  /// reason. Only the upload sheet offers it, and only the admin review
  /// can turn one into an accepted document.
  static const otherDocType = 'OTHER';

  Future<DocCheckStatus> checkStatus({String? userId}) async {
    final uid = userId ?? _client.auth.currentUser?.id;
    if (uid == null) return DocCheckStatus.required;
    try {
      final rows = await _client
          .from('user_documents')
          .select('document_type, verification_status')
          .eq('user_id', uid);
      for (final r in rows as List) {
        final status = (r['verification_status'] as String?) ?? 'MANUAL_REVIEW';
        if (status == 'SUSPECTED_FRAUD') continue;
        if (acceptedDocTypes.containsKey(r['document_type'] as String)) {
          return DocCheckStatus.satisfied;
        }
      }
      return DocCheckStatus.required;
    } catch (e) {
      // Previously `catch (_)`, which made three completely different
      // failures indistinguishable: a missing/renamed column (PostgREST
      // PGRST204), an RLS denial, and a timeout all returned the same silent
      // checkFailed. A schema error here is permanent and would otherwise
      // look identical to a blip forever, so record which it was.
      debugPrint('ProviderDocGate.checkStatus failed for $uid: '
          '${e.runtimeType}: $e');
      return DocCheckStatus.checkFailed;
    }
  }

  /// The honest display state: what is actually on file, and has anybody
  /// actually verified it.
  ///
  /// Precedence when several documents exist (a rejected one plus a freshly
  /// uploaded replacement, say): the most advanced state wins, so uploading a
  /// new ID after a rejection immediately reads as "in review" again rather
  /// than staying stuck on "rejected".
  Future<DocReviewState> reviewState({String? userId}) async {
    final uid = userId ?? _client.auth.currentUser?.id;
    if (uid == null) return DocReviewState.none;
    try {
      final rows = await _client
          .from('user_documents')
          .select('document_type, verification_status')
          .eq('user_id', uid);
      var sawPending = false;
      var sawRejected = false;
      var sawFlagged = false;
      for (final r in rows as List) {
        if (!acceptedDocTypes.containsKey(r['document_type'] as String)) {
          continue;
        }
        switch ((r['verification_status'] as String?) ?? 'MANUAL_REVIEW') {
          case 'AUTO_APPROVED':
          case 'VERIFIED':
            return DocReviewState.verified;
          case 'REJECTED':
            sawRejected = true;
          case 'SUSPECTED_FRAUD':
            sawFlagged = true;
          default:
            // MANUAL_REVIEW, and anything a future version adds that we do
            // not recognise: shown as "still waiting", never as verified.
            sawPending = true;
        }
      }
      if (sawPending) return DocReviewState.pending;
      if (sawRejected) return DocReviewState.rejected;
      if (sawFlagged) return DocReviewState.flagged;
      return DocReviewState.none;
    } catch (e) {
      debugPrint('ProviderDocGate.reviewState failed for $uid: '
          '${e.runtimeType}: $e');
      return DocReviewState.unknown;
    }
  }

  /// Whether the document gate should let a protected action through.
  ///
  /// FAIL-OPEN, and that is deliberate: a transient network error or an
  /// unreachable server must not lock a provider out of their own business.
  /// The server-side RPC provider_docs_satisfied() re-checks on protected
  /// writes, so this is a UX affordance, not the security boundary.
  ///
  /// Do NOT use this to decide whether to SHOW the user anything. A failed
  /// check returns true here, so a caller prompting on `!isSatisfied()` hides
  /// its own notice precisely when the check is broken — the user is left
  /// with no prompt and an open gate. [checkStatus] answers the same gating
  /// question with a third state, but it is still not a DISPLAY status:
  /// anything shown to the user must use [reviewState], which distinguishes
  /// "queued for review" from "verified".
  Future<bool> isSatisfied({String? userId}) async {
    final status = await checkStatus(userId: userId);
    return status != DocCheckStatus.required;
  }

  /// Blocking reason shown before opening the upload sheet.
  static const blockingMessage =
      'Verify your identity to continue. Choose the document type you have '
      'and upload it — a one-time ID check. If it has a QR code, it is '
      'verified automatically.';

  /// Runs the upload + QR-verification flow inline. Returns true when the
  /// gate is satisfied (either already, or after successful uploads).
  ///
  /// Reuses the exact signup pipeline: DocumentUploadService.uploadAndRecord
  /// (private user-documents bucket + user_documents row), then the
  /// document-verify Edge Function for QR-capable ID types.
  Future<bool> ensureDocuments(BuildContext context) async {
    // Every branch below gives the user visible feedback. The previous
    // version began with `if (await isSatisfied()) return true;`, so tapping
    // "Verify your account" (or the profile menu entry) on an already-verified
    // account returned instantly having opened nothing and said nothing —
    // indistinguishable from a dead button.
    final status = await reviewState();

    switch (status) {
      case DocReviewState.verified:
        final addAnother = await _showAlreadyVerified(context);
        if (addAnother != true || !context.mounted) return true;
      case DocReviewState.unknown:
        // The gate itself fails OPEN, so protected actions still work. But a
        // failed check is not a passed check, and silently opening the upload
        // sheet would be misleading — say what happened and offer a retry.
        final retry = await _showCheckFailed(context);
        if (retry != true || !context.mounted) return true;
      // Nothing on file, a document waiting for review, a refused one and a
      // flagged one all go straight to the upload sheet. That is the change:
      // this used to branch on the GATING status, where a document merely
      // queued for review reads as `satisfied`, so tapping through from the
      // "we received your document" notice answered "you are already
      // verified, add another?" — and a user whose ID had been REFUSED was
      // told the same thing.
      case DocReviewState.none:
      case DocReviewState.pending:
      case DocReviewState.rejected:
      case DocReviewState.flagged:
        break;
    }

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _DocUploadSheet(),
    );
    return ok == true;
  }

  /// Confirms the account is verified and offers to add another document.
  /// Returns true when the caller should proceed to the upload sheet.
  ///
  /// The dialog body is [AlreadyVerifiedDialog], a public widget so the
  /// overflow regression test can drive the real thing — a test against a
  /// copy of the layout would not catch the layout regressing.
  Future<bool?> _showAlreadyVerified(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlreadyVerifiedDialog(
        acceptedTypeNames: acceptedDocTypes.values.toList(),
      ),
    );
  }

  /// Reports a failed check and offers a retry. Returns true when the caller
  /// should proceed to the upload sheet anyway.
  Future<bool?> _showCheckFailed(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (_) => const DocumentCheckFailedDialog(),
    );
  }
}

/// "You are already verified" confirmation, shown by
/// [ProviderDocGate.ensureDocuments].
///
/// Public so it can be widget-tested. `scrollable: true` is on the AlertDialog
/// itself rather than passed via `isScrollControlled` at the showDialog call
/// site: AlertDialog caps its content height without scrolling it, which is
/// what overflowed the staff delete confirmation, and making it a property of
/// the widget means no caller can forget it.
class AlreadyVerifiedDialog extends StatelessWidget {
  const AlreadyVerifiedDialog({super.key, required this.acceptedTypeNames});

  final List<String> acceptedTypeNames;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.verified_user,
          color: AppTheme.primaryGreen, size: 32),
      title: const Text('Account verified'),
      content: Text(
        'You already have an accepted ID document on file'
        ' (${acceptedTypeNames.join(', ')}), so your provider actions '
        'are unlocked.',
        style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Add another'),
        ),
      ],
    );
  }
}

/// "We could not determine your verification status" notice.
///
/// Deliberately not an error: the gate fails OPEN, so a failed check never
/// blocks a provider. Saying so plainly stops the message reading as "you are
/// in trouble" when nothing is actually blocked.
class DocumentCheckFailedDialog extends StatelessWidget {
  const DocumentCheckFailedDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.cloud_off_outlined,
          color: AppTheme.error, size: 32),
      title: const Text('Could not check your documents'),
      content: const Text(
        'We could not reach the server to confirm your verification '
        'status. Your provider actions are not blocked by this.',
        style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Try again'),
        ),
      ],
    );
  }
}

class _DocUploadSheet extends StatefulWidget {
  const _DocUploadSheet();

  @override
  State<_DocUploadSheet> createState() => _DocUploadSheetState();
}

class _DocUploadSheetState extends State<_DocUploadSheet> {
  // Step 1: pick the document type. Step 2: pick the file and upload.
  // Step 2.5 (only when the type is OTHER): name the document, because a
  // row that just says "Other" is unreviewable — the reviewer needs to know
  // whether they are looking at a business licence or a health certificate.
  // Task 9: the type choice lives HERE, immediately before the upload —
  // never at signup.
  int _step = 0;
  String? _selectedType;
  File? _file;
  bool _uploading = false;
  String? _error;
  String? _outcome;
  final _otherLabelCtrl = TextEditingController();

  @override
  void dispose() {
    _otherLabelCtrl.dispose();
    super.dispose();
  }

  final _picker = ImagePicker();

  Future<void> _pick() async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked == null) return;
    setState(() {
      _file = File(picked.path);
      _error = null;
    });
  }

  Future<void> _submit() async {
    final docType = _selectedType;
    if (_file == null || docType == null) {
      setState(() => _error = 'Choose a document type and select the file.');
      return;
    }
    final otherLabel = _otherLabelCtrl.text.trim();
    if (docType == ProviderDocGate.otherDocType && otherLabel.isEmpty) {
      setState(() => _error =
          'Say what this document is — the person who reviews it needs to know.');
      return;
    }
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser!.id;

      await DocumentUploadService.instance.uploadAndRecord(
        file: _file!,
        userId: userId,
        documentType: docType,
        otherDocumentLabel:
            docType == ProviderDocGate.otherDocType ? otherLabel : null,
      );

      // QR verification agent (Task 4) on the uploaded document —
      // identity types only. An OTHER document has no QR payload shape to
      // validate (the Edge Function's DocType union does not include it), so
      // invoking it would either throw or misroute the row; it goes straight
      // to the manual queue, which is the only review that can accept it.
      String? outcome;
      if (docType != ProviderDocGate.otherDocType) {
        try {
        final docs = await client
            .from('user_documents')
            .select('id')
            .eq('user_id', userId)
            .eq('document_type', docType)
            .order('uploaded_at', ascending: false)
            .limit(1);
        if ((docs as List?)?.isNotEmpty ?? false) {
          final docId = (docs as List).first['id'] as String;
          final res = await client.functions
              .invoke('document-verify', body: {'document_id': docId});
          final status = (res.data as Map<String, dynamic>?)?['status'];
          if (status == 'AUTO_APPROVED') {
            outcome = 'Document verified automatically — you are all set.';
          } else if (status == 'SUSPECTED_FRAUD') {
            outcome =
                'We could not verify your document automatically. It was '
                'flagged for a manual check — our team will review it shortly.';
          } else {
            outcome =
                'No readable QR found. Sent to our team for a manual check '
                'instead — nothing is blocked.';
          }
        }
        } catch (_) {
          // Agent unreachable → manual review (default state).
        }
      }

      if (!mounted) return;
      setState(() {
        _uploading = false;
        _outcome = outcome ?? 'Document received. You can continue.';
      });
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        // The shared mapper, not the exception's first line: a storage or
        // RLS failure carries bucket names and policy detail that mean
        // nothing to the person uploading their ID.
        _error = friendlyError(e, context: 'Upload failed');
      });
    }
  }

  /// One prompt instead of two: the OTHER flow already makes the uploader
  /// name the document, so "Upload & verify" reads wrong for a sheet whose
  /// verdict for OTHER is always a human looking at it.
  @override
  Widget build(BuildContext context) {
    final showOtherLabel = _selectedType == ProviderDocGate.otherDocType;
    return AlertDialog(
      title: Text(_step == 0 ? 'Choose document type' : 'Upload your document'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(ProviderDocGate.blockingMessage),
            const SizedBox(height: 16),
            if (_step == 0) ...[
              for (final e in ProviderDocGate.acceptedDocTypes.entries) ...[
                _typeOption(e.key, e.value),
                const SizedBox(height: 8),
              ],
              // The fourth choice: a document the fixed three do not cover.
              // Step 2.5 (naming it) opens right after the file is chosen,
              // so the label is typed while the document is in hand.
              _typeOption(ProviderDocGate.otherDocType, 'Other'),
            ] else ...[
              _slot(),
              if (showOtherLabel) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _otherLabelCtrl,
                  textCapitalization: TextCapitalization.sentences,
                  maxLength: 60,
                  decoration: const InputDecoration(
                    labelText: 'What is this document?',
                    hintText: 'e.g. business licence, health certificate',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              // Said out loud because it is a location: the app takes ONE fix
              // at the moment of upload as a verification signal, keeps it on
              // that document row, and never tracks the person afterwards.
              const Text(
                'We note your location once, at the moment you upload, as a '
                'verification signal. It is not tracked, and turning GPS off '
                'does not block your upload.',
                style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
              ),
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: _uploading
                    ? null
                    : () => setState(() {
                          _step = 0;
                          _file = null;
                          _otherLabelCtrl.clear();
                        }),
                icon: const Icon(Icons.arrow_back, size: 16),
                label: const Text('Change document type'),
              ),
            ],
            if (_outcome != null) ...[
              const SizedBox(height: 12),
              Text(_outcome!,
                  style: const TextStyle(
                      fontSize: 13, color: AppTheme.success)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style: const TextStyle(fontSize: 13, color: AppTheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _uploading ? null : () => Navigator.pop(context, false),
          child: const Text('Later'),
        ),
        if (_step == 1)
          FilledButton(
            onPressed: (_uploading || _file == null) ? null : _submit,
            child: Text(_uploading ? 'Uploading…' : 'Upload document'),
          ),
      ],
    );
  }

  Widget _typeOption(String key, String label) {
    return InkWell(
      // Single tap selects the type AND advances to the upload step —
      // the choice happens right before the upload, in the same flow.
      onTap: () => setState(() {
        _selectedType = key;
        _step = 1;
        _error = null;
      }),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.cardBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.radio_button_unchecked,
              color: AppTheme.textMuted,
              size: 20,
            ),
            const SizedBox(width: 10),
            Text(label, style: const TextStyle(fontSize: 14)),
          ],
        ),
      ),
    );
  }

  Widget _slot() {
    return InkWell(
      onTap: _uploading ? null : _pick,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.cardBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              _file == null ? Icons.add_a_photo_outlined : Icons.check_circle,
              color: _file == null ? AppTheme.textMuted : AppTheme.success,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _file == null
                    ? 'Take or choose the '
                        '${_selectedType == ProviderDocGate.otherDocType ? 'document' : ProviderDocGate.acceptedDocTypes[_selectedType] ?? 'document'} image'
                    : 'Selected ✓',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
