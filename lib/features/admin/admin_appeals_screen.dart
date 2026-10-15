import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';

/// Admin queue for appeal / spam-report cases submitted from the user-side
/// appeal form (`appeal_cases`). Read + resolve: an admin (or support staff)
/// opens a case, views the evidence photo via a signed URL, and marks it
/// RESOLVED or CLOSED with an optional note. Resolutions are audited by the
/// `trg_appeal_case_resolved` trigger (admin_actions).
class AdminAppealsScreen extends StatefulWidget {
  const AdminAppealsScreen({super.key});

  @override
  State<AdminAppealsScreen> createState() => _AdminAppealsScreenState();
}

class _AdminAppealsScreenState extends State<AdminAppealsScreen> {
  static const _statuses = ['OPEN', 'RESOLVED', 'CLOSED', 'ALL'];

  /// Case-type filter, on top of the status one.
  ///
  /// A password-reset request is filed by somebody who CANNOT sign in, so it
  /// arrives here with no evidence photo and possibly no phone. It is the one
  /// case type where the queue is a work list rather than a list of disputes:
  /// it goes stale in a way an appeal does not, because the person is still
  /// locked out while it sits. So it gets its own filter rather than being
  /// mixed into ALL and forgotten.
  static const _types = [
    'ALL TYPES',
    'GENERAL',
    'PASSWORD_RESET',
    'DOCUMENT_VERIFICATION',
  ];

  /// Readable label per type.
  ///
  /// The filter is a work list, so a reviewer needs to recognise the queue
  /// from its name without opening it. `DOCUMENT_VERIFICATION` arrived in
  /// 20260927000131 and is filtered on separately for the same reason
  /// PASSWORD_RESET is: a dispute about somebody's ID is reviewed against the
  /// document queue and nowhere else, so mixing it into ALL is how it gets
  /// lost.
  static const _typeLabels = {
    'GENERAL': 'Appeals',
    'PASSWORD_RESET': 'Password resets',
    'DOCUMENT_VERIFICATION': 'Document decisions',
  };

  String _filter = 'OPEN';
  String _typeFilter = 'ALL TYPES';
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _cases = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      // appeal_cases.user_id references auth.users(id) — no FK to profiles,
      // so reporter names are joined in Dart (same pattern as tickets).
      var query = client.from('appeal_cases').select('*');
      if (_filter != 'ALL') query = query.eq('status', _filter);
      if (_typeFilter != 'ALL TYPES') {
        query = query.eq('case_type', _typeFilter);
      }
      final rows = await query.order('created_at', ascending: false).limit(200);
      final cases = (rows as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();

      final userIds = cases
          .map((c) => c['user_id'] as String?)
          .whereType<String>()
          .toSet()
          .toList();
      final Map<String, Map<String, dynamic>> profilesById = {};
      if (userIds.isNotEmpty) {
        final profiles = await client
            .from('profiles')
            .select('id, full_name, phone')
            .inFilter('id', userIds);
        for (final p in (profiles as List)) {
          final pm = Map<String, dynamic>.from(p as Map);
          profilesById[pm['id'] as String] = pm;
        }
      }
      for (final c in cases) {
        c['reporter'] = profilesById[c['user_id']];
      }

      // The respondent — the account the report names — resolves the same
      // way (appeal_cases.respondent_id also has no FK to profiles).
      final respondentIds = cases
          .map((c) => c['respondent_id'] as String?)
          .whereType<String>()
          .toSet()
          .toList();
      final Map<String, Map<String, dynamic>> respondentsById = {};
      if (respondentIds.isNotEmpty) {
        final respondentRows = await client
            .from('profiles')
            .select('id, full_name')
            .inFilter('id', respondentIds);
        for (final p in respondentRows as List) {
          final pm = Map<String, dynamic>.from(p as Map);
          respondentsById[pm['id'] as String] = pm;
        }
      }
      for (final c in cases) {
        final rid = c['respondent_id'] as String?;
        c['respondent'] = rid == null ? null : respondentsById[rid];
      }

      if (!mounted) return;
      setState(() {
        _cases = cases;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load appeals');
      });
    }
  }

  Future<void> _updateStatus(Map<String, dynamic> appealCase, String status,
      {String? note}) async {
    try {
      await Supabase.instance.client.from('appeal_cases').update({
        'status': status,
        'resolved_by': Supabase.instance.client.auth.currentUser?.id,
        'resolved_at': DateTime.now().toIso8601String(),
        if (note != null && note.isNotEmpty) 'resolution_note': note,
      }).eq('id', appealCase['id'] as String);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Appeal marked $status')));
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(friendlyError(e, context: 'Could not update this appeal'))));
    }
  }

  /// Set a locked-out person's password, on a staff member's authority.
  ///
  /// The target account is NOT chosen here. The client sends the CASE id and
  /// `approve_password_reset_appeal` derives the user from the case row, so a
  /// modified client cannot point this at an arbitrary account. The gateway
  /// then does the part no SQL function can: write to auth.users with the
  /// service role, and revoke the sessions the old password was protecting.
  Future<void> _setPasswordForCase(Map<String, dynamic> c) async {
    final passwordCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    var submitting = false;
    String? error;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialog) => AlertDialog(
          title: const Text('Set a new password'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'The account holder has asked for this. Confirm you have '
                  'checked the contact details on the case, then set a '
                  'temporary password and pass it to them directly.',
                  style: const TextStyle(
                      fontSize: 13, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: passwordCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'New password',
                    helperText: 'At least 10 characters',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confirmCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Confirm new password'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Note for the case (optional)'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(error!,
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.error)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting
                  ? null
                  : () => Navigator.pop(dialogCtx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreenDark),
              onPressed: submitting
                  ? null
                  : () async {
                      final p = passwordCtrl.text;
                      if (p.length < 10) {
                        setDialog(() =>
                            error = 'Use at least 10 characters.');
                        return;
                      }
                      if (p != confirmCtrl.text) {
                        setDialog(() => error = 'The two passwords do not match.');
                        return;
                      }
                      setDialog(() {
                        submitting = true;
                        error = null;
                      });
                      try {
                        final res = await Supabase.instance.client.functions
                            .invoke('password-reset-gateway', body: {
                          'case_id': c['id'],
                          'new_password': p,
                          'note': noteCtrl.text.trim(),
                        });
                        if (res.status != 200) {
                          final data =
                              res.data is Map ? res.data as Map : const {};
                          setDialog(() => submitting = false);
                          setDialog(() {
                            error = data['error'] == 'password_not_set'
                                ? 'The case was recorded but the password was '
                                    'NOT changed. Set it by hand and close the case.'
                                : 'Could not set the password. Try again.';
                          });
                          return;
                        }
                        if (dialogCtx.mounted) {
                          Navigator.pop(dialogCtx, true);
                        }
                      } catch (_) {
                        setDialog(() {
                          submitting = false;
                          error = 'Could not reach the server. Try again.';
                        });
                      }
                    },
              child: submitting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Set password'),
            ),
          ],
        ),
      ),
    );

    passwordCtrl.dispose();
    confirmCtrl.dispose();
    noteCtrl.dispose();

    if (confirmed == true && mounted) {
      _load();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            'Password set. Every other device has been signed out. Tell the '
            'person to change it again once they are in.'),
      ));
    }
  }

  Future<void> _resolveWithNote(Map<String, dynamic> appealCase, String status) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Mark ${status.toLowerCase()}'),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'Optional note: what was decided or done?'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(status == 'RESOLVED' ? 'Resolve' : 'Close')),
        ],
      ),
    );
    if (ok != true) return;
    await _updateStatus(appealCase, status, note: ctrl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Appeals',
            style: TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: AppTheme.primaryGreenDark,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: Column(
        children: [
          // Status filter chips
          Container(
            width: double.infinity,
            color: AppTheme.primaryGreenDark,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _statuses
                    .map((s) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(s),
                            selected: _filter == s,
                            labelStyle: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _filter == s
                                  ? AppTheme.primaryGreenDark
                                  : Colors.white,
                            ),
                            selectedColor: Colors.white,
                            backgroundColor: Colors.white.withOpacity(0.15),
                            side: BorderSide.none,
                            onSelected: (_) {
                              setState(() => _filter = s);
                              _load();
                            },
                          ),
                        ))
                    .toList(),
              ),
            ),
          ),
          // Case-type filter chips
          Container(
            width: double.infinity,
            color: AppTheme.primaryGreenDark,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _types
                    .map((t) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(
                              t == 'ALL TYPES'
                                  ? 'All types'
                                  : (_typeLabels[t] ?? t),
                              style: const TextStyle(fontSize: 12),
                            ),
                            selected: _typeFilter == t,
                            labelStyle: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _typeFilter == t
                                  ? AppTheme.gold
                                  : Colors.white,
                            ),
                            selectedColor: Colors.white,
                            backgroundColor: Colors.white.withOpacity(0.15),
                            side: BorderSide.none,
                            onSelected: (_) {
                              setState(() => _typeFilter = t);
                              _load();
                            },
                          ),
                        ))
                    .toList(),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                        color: AppTheme.primaryGreen))
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: AppTheme.error)),
                              const SizedBox(height: 12),
                              FilledButton(
                                  onPressed: _load, child: const Text('Retry')),
                            ],
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: _cases.isEmpty
                            ? ListView(
                                children: const [
                                  SizedBox(height: 120),
                                  Center(
                                    child: Text(
                                      'No appeals here',
                                      style: TextStyle(
                                          color: AppTheme.textSecondary),
                                    ),
                                  ),
                                ],
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.all(12),
                                itemCount: _cases.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (_, i) =>
                                    _buildCard(_cases[i]),
                              ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> c) {
    final reporter = c['reporter'] as Map<String, dynamic>?;
    final status = (c['status'] as String?) ?? 'OPEN';
    final createdAt = DateTime.tryParse((c['created_at'] as String?) ?? '');
    final statusColor = switch (status) {
      'OPEN' => AppTheme.warning,
      'RESOLVED' => AppTheme.primaryGreen,
      _ => AppTheme.textSecondary,
    };

    return Card(
      color: AppTheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppTheme.cardBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openDetail(c),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      (reporter?['full_name'] as String?) ?? 'Unknown reporter',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(status,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: statusColor)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (c['respondent'] != null)
                Text(
                  'Reported: '
                  '${((c['respondent'] as Map)['full_name'] as String?) ?? 'Unknown'}',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary),
                ),
              _appealDescription(c),

              const SizedBox(height: 6),
              _appealContextRow(c, createdAt),

            ],
          ),
        ),
      ),
    );
  }

  /// The description rendered for the queue row, with the in-app filing tag
  /// surfaced as its own readable chip when the case was filed from a screen
  /// about a specific transaction.
  Widget _appealDescription(Map<String, dynamic> c) {
    final desc = c['description'] as String? ?? '';
    final parsed = _parseAppealContext(desc);
    if (parsed == null) {
      return Text(
        desc,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
      );
    }
    final core = parsed['core'] as String;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          core,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 4),
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppTheme.primaryGreenDark.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: AppTheme.primaryGreenDark.withValues(alpha: 0.35)),
          ),
          child: Text(
            parsed['tag'] as String,
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700,
                color: AppTheme.primaryGreenDark),
          ),
        ),
      ],
    );
  }

  /// One line under the description: the filing context (source label + order
  /// reference) when the case was handed over from an in-app door.
  Widget _appealContextRow(Map<String, dynamic> c, DateTime? createdAt) {
    final desc = c['description'] as String? ?? '';
    final parsed = _parseAppealContext(desc);
    if (parsed == null) return _timeRow(createdAt);
    final sourceLabel = parsed['source'] as String;
    final orderRef = parsed['order'];
    final parts = <String>[sourceLabel];
    if (orderRef != null && orderRef.isNotEmpty) parts.add(orderRef);
    return Text(
      parts.join(' · '),
      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
    );
  }

  Widget _timeRow(DateTime? createdAt) {
    return Text(
      createdAt != null
          ? DateFormat('d MMM yyyy, HH:mm').format(createdAt)
          : '',
      style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
    );
  }

  /// Parses the filing tag written into `description` by the appeal form when
  /// it was handed over from an in-app door with `?about=...&order=...`.
  ///
  /// The form prefixes the description with one of:
  ///   [Filed from the app — <aboutLabel> — order <orderRef>] <user text>
  ///   [Filed from the app — <aboutLabel>] <user text>
  ///   [Appeal via Help Chat — tagged: <aboutLabel>] <user text>
  ///
  /// Returns null for cases filed from the bare appeal screen.
  ///
  /// Order-reference matching is deliberately loose: the dispute door labels the
  /// order with the human-readable number the buyer already sees
  /// (`Order Vh00001`), or `Transaction <uuid>` as a fallback, so the reviewer
  /// reads which transaction the dispute is about on the very first row.
  ///
  /// The order string itself is public: it is the same human-readable label the
  /// order screen shows the buyer and that `orderLabel()`/`formatOrderNumber()`
  /// produce from the order row's `order_number` — never the raw uuid alone.
  static Map<String, String>? _parseAppealContext(String desc) {
    if (desc.isEmpty) return null;
    final orderMatch = RegExp(
        r"^\[Filed from the app — ([^\]]+?) — order (.+?)\] ")
        .firstMatch(desc);
    if (orderMatch != null) {
      return {
        'source': 'Filed from the app',
        'tag': 'Filed from the app — ${orderMatch.group(1)} — Order ${orderMatch.group(2)}',
        'about': orderMatch.group(1) ?? 'Something else',
        'order': 'Order ${orderMatch.group(2)}',
        'core': desc.substring(orderMatch.end),
      };
    }
    final labelMatch = RegExp(
        r"^\[Filed from the app — ([^\]]+)\] ")
        .firstMatch(desc);
    if (labelMatch != null) {
      return {
        'source': 'Filed from the app',
        'tag': 'Filed from the app — ${labelMatch.group(1)}',
        'about': labelMatch.group(1) ?? 'Something else',
        'core': desc.substring(labelMatch.end),
      };
    }
    final chatMatch = RegExp(r"^\[Appeal via Help Chat — tagged: ([^\]]+)\] ")
        .firstMatch(desc);
    if (chatMatch != null) {
      return {
        'source': 'Help Chat',
        'tag': 'Appeal via Help Chat — ${chatMatch.group(1)}',
        'about': chatMatch.group(1) ?? 'Something else',
        'core': desc.substring(chatMatch.end),
      };
    }
    return null;
  }

  void _openDetail(Map<String, dynamic> c) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _AppealDetailSheet(
          caseData: c,
          onResolve: _resolveWithNote,
          onSetPassword: _setPasswordForCase),
    );
  }
}

class _AppealDetailSheet extends StatefulWidget {
  final Map<String, dynamic> caseData;

  /// Resolve/close with a note. This lives on the screen, not on the sheet,
  /// because the sheet is already the bottom-most surface: it cannot open a
  /// dialog on top of itself without the dialog inheriting the sheet's
  /// barrier. The sheet only decides to ask.
  ///
  /// This is what makes `appeal_cases.resolution_note` writable at all. The
  /// buttons used to call `_updateStatus` straight through, so an appeal could
  /// be resolved but never annotated — and the helper that did ask for the
  /// note sat unreferenced in the same file.
  final void Function(Map<String, dynamic> appealCase, String status) onResolve;

  /// The password-reset action lives on the screen, not on the sheet: it needs
  /// `context` for a dialog and `_load()` to refresh the queue afterwards. The
  /// sheet only decides whether to offer it.
  final void Function(Map<String, dynamic>) onSetPassword;

  const _AppealDetailSheet({
    required this.caseData,
    required this.onResolve,
    required this.onSetPassword,
  });

  @override
  State<_AppealDetailSheet> createState() => _AppealDetailSheetState();
}

class _AppealDetailSheetState extends State<_AppealDetailSheet> {
  String? _photoUrl;
  String? _responsePhotoUrl;
  bool _photoLoading = true;
  String? _photoError;

  @override
  void initState() {
    super.initState();
    _loadPhoto();
  }

  Future<void> _loadPhoto() async {
    // A PASSWORD_RESET case has no evidence photo -- the person filing it
    // cannot sign in, which is the whole premise -- so `photo_path` is NULL.
    // This used to be `as String`, which threw on the cast and left the staff
    // member staring at an error instead of at the case they came to action.
    // A missing photo is a fact about the case, not a failure to load one.
    final path = widget.caseData['photo_path'] as String?;
    if (path == null || path.isEmpty) {
      if (!mounted) return;
      setState(() {
        _photoError = 'No photo attached';
        _photoLoading = false;
      });
      return;
    }
    try {
      final url = await Supabase.instance.client.storage
          .from('user-documents')
          .createSignedUrl(path, 60 * 60);
      if (!mounted) return;
      setState(() {
        _photoUrl = url;
        _photoLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _photoError = 'Photo unavailable';
        _photoLoading = false;
      });
    }
    // The respondent's reply evidence lives in THEIR folder; readable to the
    // admin through the same admin-read storage policy. Best effort — a
    // missing reply photo must never blank the sheet.
    final responsePath = widget.caseData['response_photo_path'] as String?;
    if (responsePath != null && responsePath.isNotEmpty) {
      try {
        final url = await Supabase.instance.client.storage
            .from('user-documents')
            .createSignedUrl(responsePath, 60 * 60);
        if (!mounted) return;
        setState(() => _responsePhotoUrl = url);
      } catch (_) {
        // Leave null; the text reply below still renders.
      }
    }
  }

  /// The filing-context header shown above the case sheet photo when the case
  /// was handed over from an in-app door about a specific transaction.
  ///
  /// The queue row already trims the tag off the description; on the sheet the
  /// reviewer is deciding, so the source, what it is about and WHICH order it is
  /// about are shown as chips rather than buried in the paragraph.
  Widget _appealContextHeader(Map<String, dynamic> c) {
    final desc = c['description'] as String? ?? '';
    final parsed = _AdminAppealsScreenState._parseAppealContext(desc);
    if (parsed == null) return const SizedBox.shrink();
    final sourceLabel = parsed['source'] as String;
    final orderRef = parsed['order'];
    final about = parsed['about'] as String;
    final parts = <Widget>[Text(sourceLabel)];
    if (orderRef != null && orderRef.isNotEmpty) {
      parts.add(
        Container(
          margin: const EdgeInsets.only(left: 8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: AppTheme.primaryGreenDark.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: AppTheme.primaryGreenDark.withValues(alpha: 0.35)),
          ),
          child: Text(
            about,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppTheme.primaryGreenDark),
          ),
        ),
      );
      parts.add(
        Container(
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: AppTheme.primaryGreen.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            orderRef,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppTheme.primaryGreen),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: parts),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.caseData;
    final reporter = c['reporter'] as Map<String, dynamic>?;
    final status = (c['status'] as String?) ?? 'OPEN';
    final createdAt = DateTime.tryParse((c['created_at'] as String?) ?? '');
    final respondedAt = DateTime.tryParse((c['responded_at'] as String?) ?? '');
    final respondentName =
        ((c['respondent'] as Map?)?['full_name'] as String?);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.92,
      maxChildSize: 0.95,
      builder: (ctx, scrollCtrl) => SingleChildScrollView(
        controller: scrollCtrl,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppTheme.cardBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    (reporter?['full_name'] as String?) ?? 'Unknown reporter',
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.textPrimary),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: (status == 'OPEN'
                            ? AppTheme.warning
                            : status == 'RESOLVED'
                                ? AppTheme.primaryGreen
                                : AppTheme.textSecondary)
                        .withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(status,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: status == 'OPEN'
                              ? AppTheme.warning
                              : status == 'RESOLVED'
                                  ? AppTheme.primaryGreen
                                  : AppTheme.textSecondary)),
                ),
              ],
            ),
            if (createdAt != null) ...[
              const SizedBox(height: 4),
              Text(DateFormat('d MMM yyyy, HH:mm').format(createdAt),
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary)),
            ],              if (respondentName != null) ...[
                const SizedBox(height: 4),
                Text('Reported: $respondentName',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary)),
              ],
              const SizedBox(height: 16),            // Filing context: when the case was handed over from an in-app
            // door about a specific transaction, the form writes the order
            // reference into the description, so the reviewer reads it before
            // the report text.
            _appealContextHeader(widget.caseData),

            // Evidence photo (private bucket → signed URL)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 220,
                width: double.infinity,
                child: _photoLoading
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: AppTheme.primaryGreen))
                    : _photoError != null
                        ? Container(
                            color: AppTheme.surface,
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.broken_image_outlined,
                                      color: AppTheme.textSecondary),
                                  const SizedBox(height: 6),
                                  Text(_photoError!,
                                      style: const TextStyle(
                                          color: AppTheme.textSecondary,
                                          fontSize: 12)),
                                ],
                              ),
                            ),
                          )
                        : _photoUrl == null
                            ? Container(
                                color: AppTheme.surface,
                                child: const Center(
                                  child: Icon(Icons.image_not_supported_outlined,
                                      color: AppTheme.textSecondary, size: 28),
                                ),
                              )
                            : Image.network(_photoUrl!, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 16),

            const Text('Report',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            SelectableText(
              (c['description'] as String?) ?? '',
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
            ),
            const SizedBox(height: 16),

            const Text('Contact',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            _contactRow(Icons.phone, (c['phone'] as String?) ?? '—'),
            if (((c['email'] as String?) ?? '').isNotEmpty)
              _contactRow(Icons.email_outlined, c['email'] as String),
            _contactRow(Icons.badge_outlined,
                (reporter?['phone'] as String?) ?? '—',
                label: 'Account phone'),            const SizedBox(height: 16),

            // The other party's reply — what makes an appeal two-directional.
            if (((c['response_text'] as String?) ?? '').isNotEmpty) ...
              [
                const Text('Respondent reply',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.info.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  c['response_text'] as String,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 13),
                ),
              ),
              if (respondedAt != null) ...[
                const SizedBox(height: 4),
                Text(
                    'Sent ${DateFormat('d MMM yyyy, HH:mm').format(respondedAt)}',
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textSecondary)),
              ],
              if (_responsePhotoUrl != null) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.network(_responsePhotoUrl!,
                      height: 160, width: double.infinity, fit: BoxFit.cover),
                ),
              ],
              const SizedBox(height: 16),
            ],
            if (((c['resolution_note'] as String?) ?? '').isNotEmpty) ...[
              const Text('Resolution note',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.primaryGreen.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  c['resolution_note'] as String,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 13),
                ),
              ),
              const SizedBox(height: 16),
            ],

            if (status == 'OPEN') ...[
              if (c['case_type'] == 'PASSWORD_RESET') ...[
                // The action that actually unblocks the person. It is NOT the
                // same as Resolve: resolving the case only files the paperwork,
                // and a password-reset case that is resolved without a password
                // being set leaves the account exactly as locked as it was,
                // with the evidence that somebody tried to help now marked
                // done. So the set-password action comes first and the plain
                // resolve is not offered for this type at all.
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.gold,
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                    onPressed: () {
                      Navigator.pop(context);
                      widget.onSetPassword(c);
                    },
                    icon: const Icon(Icons.vpn_key, size: 18),
                    label: const Text('Set a new password'),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Verify the person first using the contact details above. '
                  'Setting a password signs every other device out.',
                  style: TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 14),
              ] else ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onResolve(c, 'CLOSED');
                        },
                        child: const Text('Close case'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.primaryGreenDark),
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onResolve(c, 'RESOLVED');
                        },
                        child: const Text('Resolve'),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _contactRow(IconData icon, String value, {String? label}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppTheme.textSecondary),
          const SizedBox(width: 8),
          Text(label != null ? '$label: ' : '',
              style: const TextStyle(
                  fontSize: 13, color: AppTheme.textSecondary)),
          Expanded(
            child: SelectableText(value,
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textPrimary)),
          ),
        ],
      ),
    );
  }
}
