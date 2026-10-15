import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/captcha_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/captcha_challenge_field.dart';
import '../../core/utils/friendly_error.dart';

/// User-facing appeal / spam-report form.
///
/// Collects an evidence photo, a written report and contact details and stores
/// the case in `appeal_cases` (photo in the private `user-documents` bucket).
/// Admins review and resolve cases from Admin → Appeals.
class AppealScreen extends ConsumerStatefulWidget {
  const AppealScreen({super.key});

  @override
  ConsumerState<AppealScreen> createState() => _AppealScreenState();
}

class _AppealScreenState extends ConsumerState<AppealScreen> {
  static const _bucket = 'user-documents';

  final _formKey = GlobalKey<FormState>();
  final _descriptionCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  XFile? _photo;
  bool _submitting = false;
  bool _captchaRequired = false;
  String? _captchaId;
  int _captchaVersion = 0;
  String? _error;
  String? _caseId;

  // Task 14: chat escalations open this form pre-tagged with context
  // (?about=rider|provider|dispute|account|general&source=chat) so the case
  // lands with the right review context.
  String _about = 'general';
  bool _fromChat = false;

  /// The transaction a door handed over (?order=...), when the case is about
  /// one specific order.
  ///
  /// `appeal_cases` has no column for it, and inventing one would put the
  /// reference where no reviewer reads: the description is what the admin
  /// queue renders on every row and in the case sheet. So it is written into
  /// the description, exactly the way the chat doors already tag theirs — an
  /// admin opening "Buyer–seller dispute" reads which order it is about
  /// without asking anyone.
  String? _orderRef;

  // Respondent picker: WHO the report is about (optional). Filled from the
  // counterparties the submitter actually met — sellers from their orders,
  // drivers from their rides — resolved server-side by appeal_counterparties()
  // so no extra table reads (or RLS guesses) happen here. Stored as
  // appeal_cases.respondent_id, which is what gives the other party a screen
  // and a reply path (My Appeals → "Against me").
  List<Map<String, String>> _counterparties = const [];
  String? _respondentId;

  static const _aboutLabels = {
    'rider': 'Ride / driver issue',
    'provider': 'Provider / selling issue',
    'dispute': 'Buyer–seller dispute',
    'account': 'Account status (ban / suspension / approval)',
    'document': 'ID / document verification decision',
    'general': 'Something else',
  };

  /// The `_about` values that are stored as `appeal_cases.case_type` rather
  /// than only being read by a human.
  ///
  /// Until 0131 a document dispute could only be filed as a GENERAL appeal:
  /// it arrived, it worked, and it was invisible -- mixed into a queue of
  /// disputes about other people and filtered out of every document view. A
  /// real column is the only thing a reviewer can filter on, so the choice the
  /// person already makes here is written down where the server can see it.
  /// Everything else stays GENERAL, which is what the column already defaults
  /// to, so no existing case changes meaning.
  static const _caseTypeForAbout = {
    'document': 'DOCUMENT_VERIFICATION',
  };

  String get _caseType => _caseTypeForAbout[_about] ?? 'GENERAL';

  @override
  void initState() {
    super.initState();
    _loadCaptchaRequirement();
    _loadCounterparties();
  }

  /// Loads the "who is this about" picker. A failed load must never block
  /// the appeal itself, so errors collapse to an empty (hidden) picker.
  Future<void> _loadCounterparties() async {
    try {
      final rows = await Supabase.instance.client.rpc('appeal_counterparties');
      final items = <Map<String, String>>[];
      final seen = <String>{};
      for (final r in rows as List) {
        final m = Map<String, dynamic>.from(r as Map);
        final uid = m['counterpart_user_id'] as String?;
        if (uid == null || uid.isEmpty || !seen.add(uid)) continue;
        items.add({
          'user_id': uid,
          'name': (m['display_name'] as String?) ?? 'Aliob provider',
          'kind': (m['kind'] as String?) ?? '',
        });
      }
      if (!mounted) return;
      setState(() => _counterparties = items);
    } catch (_) {
      // Intentionally swallowed: optional context, never a blocker.
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Read the deep-link query params once the router state is available.
    final qp = GoRouterState.of(context).uri.queryParameters;
    final about = qp['about'];
    if (about != null && _aboutLabels.containsKey(about)) {
      _about = about;
    }
    _fromChat = qp['source'] == 'chat';
    // The transaction a door was looking at, when it had one. Capped so a
    // hand-edited URL cannot push a wall of text into the case sheet.
    final order = qp['order']?.trim();
    if (order != null && order.isNotEmpty) {
      _orderRef = order.length > 64 ? order.substring(0, 64) : order;
    }
  }

  Future<void> _loadCaptchaRequirement() async {
    final required = await CaptchaService.instance.isRequired();
    if (mounted) setState(() => _captchaRequired = required);
  }

  @override
  void dispose() {
    _descriptionCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    // Camera first, gallery as fallback, mirroring the signup document flow.
    try {
      final fromCamera = await ImagePicker().pickImage(
        source: ImageSource.camera,
        imageQuality: 70,
        maxWidth: 1600,
      );
      if (fromCamera != null) {
        setState(() => _photo = fromCamera);
        return;
      }
      final fromGallery = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 70,
        maxWidth: 1600,
      );
      if (fromGallery != null) setState(() => _photo = fromGallery);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(friendlyError(e, context: 'Could not open the camera'))),
      );
    }
  }

  String? _validateEmail(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return null; // optional field
    final emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    return emailRe.hasMatch(value) ? null : 'Enter a valid email address';
  }

  String? _validatePhone(String? v) {
    final value = v?.trim() ?? '';
    final phoneRe = RegExp(r'^(?:\+?251|0)?9\d{8}$');
    return phoneRe.hasMatch(value.replaceAll(RegExp(r'[\s-]'), ''))
        ? null
        : 'Enter a valid Ethiopian phone number (e.g. 0912345678)';
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_photo == null) {
      setState(() => _error = 'Please attach a photo to support your appeal.');
      return;
    }
    if (_captchaRequired && _captchaId == null) {
      setState(() => _error = 'Please complete the security check first.');
      return;
    }
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      setState(() => _error = 'You need to be signed in to submit an appeal.');
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final client = Supabase.instance.client;

      // Task 14: chat-escalated appeals carry their context into the stored
      // description so the case lands with the right review context —
      // appeal_cases has no dedicated tag column, so we prefix the text that
      // admins/staff already read on every case.
      //
      // The in-app doors carry theirs the same way. A dispute filed from the
      // payment step or an order screen used to arrive as an untagged
      // paragraph: the choice the person made (`?about=dispute`) and the
      // transaction they were looking at were both dropped, so the reviewer
      // had to ask which order it was. The tag is the label the person chose
      // and the reference is the one the order screen shows them.
      final aboutLabel = _aboutLabels[_about] ?? 'Something else';
      final String contextPrefix;
      if (_fromChat) {
        contextPrefix = '[Appeal via Help Chat — tagged: $aboutLabel] ';
      } else if (_orderRef != null) {
        contextPrefix = '[Filed from the app — $aboutLabel — '
            'order ${_orderRef!}] ';
      } else if (_about != 'general') {
        contextPrefix = '[Filed from the app — $aboutLabel] ';
      } else {
        contextPrefix = '';
      }
      final descriptionText =
          '$contextPrefix${_descriptionCtrl.text.trim()}';

      // 1. Upload the evidence photo (private bucket, same one signup uses).
      final path =
          '${user.id}/appeal_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await client.storage.from(_bucket).upload(
            path,
            File(_photo!.path),
            fileOptions: const FileOptions(upsert: true),
          );

      // 2. Store the case.
      final inserted = await client
          .from('appeal_cases')
          .insert({
            'user_id': user.id,
            'photo_path': path,
            'description': descriptionText,
            'phone': _phoneCtrl.text.trim(),
            'email': _emailCtrl.text.trim().isEmpty
                ? null
                : _emailCtrl.text.trim(),
            'captcha_id': _captchaId,
            'case_type': _caseType,
            if (_respondentId != null) 'respondent_id': _respondentId,
          })
          .select('id')
          .single();

      if (!mounted) return;
      setState(() {
        _caseId = inserted['id'] as String;
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      final raw = e.toString();
      final captchaFailed = raw.contains('CAPTCHA_REQUIRED');
      setState(() {
        _submitting = false;
        if (captchaFailed) {
          _captchaId = null;
          _captchaVersion++;
        }
        _error = captchaFailed
            ? 'The security check expired. Please solve a new one and submit again.'
            : 'Could not submit your appeal. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Submit an Appeal',
            style: TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: AppTheme.primaryGreenDark,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _caseId != null ? _buildSuccess() : _buildForm(),
    );
  }

  Widget _buildSuccess() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle_outline,
                color: AppTheme.primaryGreen, size: 72),
            const SizedBox(height: 16),
            const Text(
              'Appeal submitted',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary),
            ),
            const SizedBox(height: 8),
            const Text(
              'Our team will review your case and contact you using the '
              'details you provided. You can follow up any time through '
              'Help & Support.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Task 14: context banner when opened from the chat escalation —
            // shows what the case will be tagged as.
            if (_fromChat)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.teal.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.teal.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.support_agent,
                        size: 20, color: AppTheme.teal),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Sent from Help Chat — this appeal will be tagged as: '
                        '${_aboutLabels[_about] ?? 'Something else'}.',
                        style: const TextStyle(
                            fontSize: 12.5, color: AppTheme.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.primaryGreen.withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline,
                      color: AppTheme.primaryGreenDark, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Wrongly flagged, scammed, or want to report someone? '
                      'Tell us what happened and attach a photo as evidence. '
                      'Our team reviews every appeal.',
                      style: TextStyle(
                          fontSize: 13, color: AppTheme.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // What kind of problem is this? The first question a reviewer
            // asks, and until now the only way to answer it was to read the
            // prose. `_about` existed but was only ever set by a chat deep
            // link, so choosing "ID / document verification decision" was
            // unreachable for anybody filing an appeal directly -- which is
            // how a document dispute ended up as an untagged GENERAL appeal in
            // a queue of disputes about other people.
            Text('What is this about?',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _about,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Type of issue'),
              items: _aboutLabels.entries
                  .map((e) => DropdownMenuItem<String>(
                        value: e.key,
                        child: Text(e.value,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: _submitting
                  ? null
                  : (v) {
                      if (v != null) setState(() => _about = v);
                    },
            ),
            const SizedBox(height: 20),

            // Who is this about? Optional. Names the respondent who then
            // sees the case and can reply (see My Appeals).
            if (_counterparties.isNotEmpty) ...[
              Text('Who is this about?',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              const Text(
                'Optional — the person you name can see this report and reply to it.',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _respondentId,
                isExpanded: true,
                hint: const Text('No specific person'),
                decoration: const InputDecoration(labelText: 'Report about'),
                items: _counterparties
                    .map((c) => DropdownMenuItem<String>(
                          value: c['user_id'],
                          child: Text(
                            '${c['name']} · '
                            '${c['kind'] == 'DRIVER' ? 'driver' : 'seller'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ))
                    .toList(),
                onChanged: _submitting
                    ? null
                    : (v) => setState(() => _respondentId = v),
              ),
            ],
            const SizedBox(height: 20),

            // Photo attachment
            Text('Evidence photo',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: _submitting ? null : _pickPhoto,
              child: Container(
                height: 160,
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: AppTheme.cardBorder,
                    width: 1.2,
                  ),
                ),
                child: _photo != null
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child:
                                Image.file(File(_photo!.path), fit: BoxFit.cover),
                          ),
                          Positioned(
                            top: 6,
                            right: 6,
                            child: CircleAvatar(
                              radius: 16,
                              backgroundColor: Colors.black54,
                              child: IconButton(
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.close,
                                    size: 16, color: Colors.white),
                                onPressed:
                                    _submitting ? null : () => setState(() => _photo = null),
                              ),
                            ),
                          ),
                        ],
                      )
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.add_a_photo_outlined,
                              color: AppTheme.textSecondary, size: 32),
                          SizedBox(height: 8),
                          Text('Tap to take or choose a photo',
                              style: TextStyle(color: AppTheme.textSecondary)),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 20),

            BirrTextField(
              label: 'Report / description',
              hint: 'Describe what happened in as much detail as you can',
              controller: _descriptionCtrl,
              maxLines: 5,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Please describe your case' : null,
            ),
            const SizedBox(height: 16),
            BirrTextField(
              label: 'Phone number',
              hint: '09xxxxxxxx',
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              validator: _validatePhone,
            ),
            const SizedBox(height: 16),
            BirrTextField(
              label: 'Email (optional)',
              hint: 'you@example.com',
              controller: _emailCtrl,
              keyboardType: TextInputType.emailAddress,
              validator: _validateEmail,
            ),

            if (_captchaRequired) ...[
              const SizedBox(height: 16),
              CaptchaChallengeField(
                key: ValueKey('appeal-captcha-$_captchaVersion'),
                onVerified: (id) => setState(() => _captchaId = id),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppTheme.error, fontSize: 13),
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _submitting || (_captchaRequired && _captchaId == null)
                  ? null
                  : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primaryGreenDark,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Submit appeal',
                      style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
