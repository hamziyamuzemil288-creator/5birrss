import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/staff_admin_service.dart';
import '../../core/services/staff_gateway_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/utils/friendly_error.dart';

/// Staff / role-hierarchy management.
///
/// Hierarchy (enforced server-side by the staff RPCs — hiding UI here is
/// convenience, not the security boundary):
///   CEO            top of both branches; only the CEO creates super admins
///   Super Admin    ADMIN branch; monitors sub-admins, sees reports/expenses
///   Me (owner)     ME branch; jointly controls sub-admins with Super Admin
///   Sub-Admin      categorized; explicit permission list ∩ categories
class AdminStaffScreen extends ConsumerStatefulWidget {
  const AdminStaffScreen({super.key});

  @override
  ConsumerState<AdminStaffScreen> createState() => _AdminStaffScreenState();
}

/// The job catalogue as read from `staff_jobs`, grouped for display.
///
/// Falls back to the hard-coded maps when the read has not landed (or failed)
/// so the section never renders as an empty box — but the SERVER is the
/// authority, and set_staff_jobs() refuses anything not in the catalogue, so
/// the fallback can only ever be a stale subset, never an invented job.
List<MapEntry<String, List<String>>> _jobGroupsFrom(
  List<Map<String, dynamic>> catalogue,
) {
  if (catalogue.isEmpty) {
    return _AdminStaffScreenState._permissionGroups.entries
        .map((e) => MapEntry(e.key, e.value))
        .toList();
  }
  final byGroup = <String, List<String>>{};
  for (final job in catalogue) {
    final key = job['key']?.toString();
    final label = job['label']?.toString();
    if (key == null || label == null) continue;
    byGroup.putIfAbsent(job['group_name']?.toString() ?? 'General', () => []).add(key);
  }
  return byGroup.entries.toList();
}

Map<String, String> _jobLabelsFrom(List<Map<String, dynamic>> catalogue) {
  if (catalogue.isEmpty) return _AdminStaffScreenState._permissionOptions;
  return {
    for (final job in catalogue)
      if (job['key'] != null && job['label'] != null)
        job['key'].toString(): job['label'].toString(),
  };
}

class _AdminStaffScreenState extends ConsumerState<AdminStaffScreen> {
  List<Map<String, dynamic>> _staff = [];
  List<Map<String, dynamic>> _categories = [];

  /// `admin_staff_roster()` keyed by staff id: the rank, the assigned CITY,
  /// the granted obligations and the movement counters that the `staff` table
  /// read above cannot supply.
  ///
  /// Kept as a lookup rather than a second list on purpose. The card list is
  /// already built from `_staff`; joining in place would mean two sources of
  /// truth for "who is on the roster", and they can disagree -- the RPC is
  /// server-authoritative and the direct read is what the RLS policy allows.
  /// This is a per-row ENRICHMENT, so a missing roster degrades the card
  /// instead of blanking the screen.
  final Map<String, Map<String, dynamic>> _roster = {};

  /// The assignable jobs, read from `staff_jobs`. Empty until the first load
  /// lands, which is the only time the hard-coded fallback is used.
  List<Map<String, dynamic>> _jobCatalogue = [];
  bool _loading = true;
  String? _error;
  bool _isSuperAdmin = false;
  bool _isCeo = false;

  /// Editor submit state — rendered INSIDE the sheet. Errors must surface
  /// here: ScaffoldMessenger snackbars fire on the Scaffold BEHIND the modal
  /// bottom sheet, where the sheet hides them (the silent "nothing happens"
  /// staff-creation bug).
  String? _sheetError;
  bool _submitting = false;

  /// UX: which collapsible category groups are expanded in the editor.
  /// Kept across sheet re-openings so the CEO's choices persist.
  final Set<String> _expandedCategoryGroups = {};

  /// Permission vocabulary. The three `view_*` entries are the
  /// reports / expenses / auth-log visibility the hierarchy spec adds;
  /// action permissions stay as before.
  /// The job catalogue, read from the DATABASE.
  ///
  /// This used to be a hard-coded Dart map with a second hard-coded grouping
  /// beside it, while the authoritative list lived in a SQL CHECK constraint —
  /// three copies of the same nine strings, and adding a job meant editing all
  /// three. The catalogue is now `staff_jobs` (migration 20260927000034), so
  /// the CEO picks from what the server will actually accept.
  ///
  /// Populated by [_loadJobs]; the two maps below are only the fallback for
  /// the moment before the first read lands, so the section never renders as
  /// an empty box.
  static const _permissionOptions = {
    'sales_transactions': 'Sales & transactions',
    'registrations': 'Registrations',
    'document_verification': 'Document verification',
    'category_management': 'Category management',
    'support_chat': 'Support / chat',
    'payment_verification': 'Payment verification',
    'admin_history': 'View admin history',
    'view_reports': 'View reports',
    'view_expenses': 'View expenses',
    'view_auth_logs': 'View auth logs',
  };

  /// UX: permissions grouped into three purpose labels so the checklist
  /// reads as three short rows inside one collapsible section instead of a
  /// nine-item wall. Keys must all exist in _permissionOptions.
  static const _permissionGroups = <String, List<String>>{
    'Daily operations': [
      'sales_transactions',
      'registrations',
      'category_management',
    ],
    'Support & payments': [
      'support_chat',
      'payment_verification',
      'document_verification',
    ],
    'Oversight & reports': [
      'admin_history',
      'view_reports',
      'view_expenses',
      'view_auth_logs',
    ],
  };

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
      // Identity via the server helpers: is_ceo() covers the true Admin
      // (the Supabase-registered owner account, which never has a staff
      // row) and is_super_admin() the active Super Admin staff row.
      if (client.auth.currentUser != null) {
        try {
          _isCeo = await client.rpc('is_ceo') == true;
        } catch (_) {
          _isCeo = false;
        }
        try {
          _isSuperAdmin = await client.rpc('is_super_admin') == true;
        } catch (_) {
          _isSuperAdmin = false;
        }
      }
      final rows = await client.from('staff').select().order('created_at');
      // The roster RPC is a SEPARATE read with its own failure handling, for
      // the same reason as the job list below. It is the only source of a
      // staff member's city and granted obligations, but the directory must
      // still render if it is unavailable -- losing the screen entirely
      // because an enrichment RPC is down would be a far worse regression
      // than a card without a city chip.
      Map<String, Map<String, dynamic>> roster = {};
      try {
        final rosterRows = await client.rpc('admin_staff_roster');
        for (final r in (rosterRows as List)) {
          final row = Map<String, dynamic>.from(r as Map);
          final id = row['staff_id']?.toString();
          if (id != null && id.isNotEmpty) roster[id] = row;
        }
      } catch (_) {
        // Cards fall back to the fields the `staff` read already gave us.
      }
      // The job list is a SEPARATE read with its own failure handling: if it
      // fails, the directory must still render and the editor must still open
      // with the fallback list, rather than one unavailable table blanking the
      // whole management screen.
      try {
        final jobs = await client
            .from('staff_jobs')
            .select('key, label, description, group_name, sort_order')
            .eq('is_active', true)
            .order('sort_order');
        if (mounted) setState(() => _jobCatalogue = List<Map<String, dynamic>>.from(jobs as List));
      } catch (_) {
        // Fallback maps below cover this.
      }
      final staff = List<Map<String, dynamic>>.from(rows as List);
      // Vehicle categories for sub-admin scope assignment.
      List<Map<String, dynamic>> cats = [];
      try {
        final catRows = await client
            .from('categories')
            .select('id,name,sector,parent_id')
            .eq('is_active', true)
            .order('sort_order');
        cats = List<Map<String, dynamic>>.from(catRows as List);
        // Nest subcategories visually under their parent: top-levels first
        // (by sort_order), then each parent's children right after it. The
        // editor indents child rows so the CEO sees the hierarchy at a
        // glance instead of a mixed flat list.
        int rank(Map<String, dynamic> c) {
          final parentId = c['parent_id'] as String?;
          final so = (c['sort_order'] as num?)?.toInt() ?? 0;
          if (parentId == null) return so * 1000;
          final parent =
              cats.where((p) => p['id'] == parentId).toList(growable: false);
          final parentSo = parent.isNotEmpty
              ? ((parent.first['sort_order'] as num?)?.toInt() ?? 999)
              : 999;
          return parentSo * 1000 + 500 + so;
        }

        cats.sort((a, b) => rank(a).compareTo(rank(b)));
      } catch (_) {
        // Category listing is optional for the editor; staff ops continue.
      }
      if (!mounted) return;
      setState(() {
        _staff = staff;
        _categories = cats;
        _roster
          ..clear()
          ..addAll(roster);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e, context: 'Could not load staff');
        _loading = false;
      });
    }
  }

  String _branchLabel(Map<String, dynamic> s) {
    if (s['is_ceo'] == true) return 'CEO';
    final branch = (s['branch'] as String?) ?? 'ADMIN';
    if (s['is_super_admin'] == true) return 'Super Admin';
    return branch == 'ME' ? 'Owner team' : 'Admin team';
  }

  Map<String, dynamic> _rosterFor(Map<String, dynamic> s) =>
      _roster[s['id']?.toString() ?? ''] ?? const {};

  /// The person's RANK: their job title. Read from the roster first because
  /// `staff.job_role` is only written by the CEO's terms editor, and falls
  /// back to the legacy permission list so a card is never blank on that line.
  String _rankLabel(Map<String, dynamic> s) {
    final r = _rosterFor(s);
    final role = ((r['job_role'] as String?) ?? (s['job_role'] as String?) ?? '')
        .trim();
    if (role.isNotEmpty) return role;
    final branch = _branchLabel(s);
    if (branch == 'Admin team' || branch == 'Owner team') return 'Sub-admin';
    return branch;
  }

  /// The assigned CITY, or an explicit "every city" when the person is
  /// unscoped. Showing the difference matters: an admin with no city assigned
  /// sees the whole country, and a row that silently omits the chip is
  /// indistinguishable from a row whose city failed to load.
  String? _cityLabel(Map<String, dynamic> s) {
    final r = _rosterFor(s);
    final city = ((r['city'] as String?) ?? (s['city'] as String?) ?? '').trim();
    return city.isEmpty ? null : city;
  }

  /// Granted obligations, as display labels resolved through the job
  /// catalogue so the card says "Sales & transactions" and not
  /// "sales_transactions". Unknown keys fall back to a prettified form
  /// rather than being dropped -- a new job the catalogue has not caught up
  /// with must still be visible.
  List<String> _obligationLabels(Map<String, dynamic> s) {
    final r = _rosterFor(s);
    final keys = ((r['obligations'] as List?) ?? const <dynamic>[])
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList();
    final source = keys.isNotEmpty
        ? keys
        : (((r['legacy_permissions'] as List?) ?? const <dynamic>[])
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList());
    return source.map(_obligationLabel).toList();
  }

  String _obligationLabel(String key) {
    final known = _jobCatalogue
        .where((j) => j['key'] == key)
        .map((j) => (j['label'] as String?)?.trim())
        .whereType<String>()
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (known.isNotEmpty) return known;
    return _permissionOptions[key] ??
        key
            .split('_')
            .where((w) => w.isNotEmpty)
            .map((w) => w[0].toUpperCase() + w.substring(1))
            .join(' ');
  }

  /// The movement counters: tasks completed, open warnings, and when this
  /// person was last seen doing something. Rendered as one dense line -- the
  /// CEO's question is "are they working", not "give me their biography".
  String? _movementLabel(Map<String, dynamic> s) {
    final r = _rosterFor(s);
    if (r.isEmpty) return null;
    final done = (r['completed_tasks'] as num?)?.toInt() ?? 0;
    final open = (r['open_warnings'] as num?)?.toInt() ?? 0;
    final last = (r['last_activity_at'] as String?) ?? '';
    final parts = <String>['$done done'];
    if (open > 0) parts.add('$open open warning${open == 1 ? '' : 's'}');
    final when = _relativeTime(last);
    if (when != null) parts.add(when);
    return parts.join(' · ');
  }

  /// Coarse relative time. Deliberately not a date: "3d ago" answers "is this
  /// person alive" without inventing precision, and a null for a missing or
  /// unparseable value keeps the line honest instead of printing "never".
  String? _relativeTime(String iso) {
    if (iso.isEmpty) return null;
    final at = DateTime.tryParse(iso);
    if (at == null) return null;
    final d = DateTime.now().difference(at.toLocal());
    if (d.isNegative || d.inMinutes < 1) return 'active now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 30) return '${d.inDays}d ago';
    return '${d.inDays ~/ 30}mo ago';
  }

  IconData _branchIcon(Map<String, dynamic> s) {
    if (s['is_ceo'] == true) return Icons.workspace_premium_outlined;
    if (s['is_super_admin'] == true) return Icons.shield_outlined;
    return ((s['branch'] as String?) ?? 'ADMIN') == 'ME'
        ? Icons.badge_outlined
        : Icons.support_agent_outlined;
  }

  Future<void> _openEditor([Map<String, dynamic>? existing]) async {
    final nameController =
        TextEditingController(text: existing?['name'] as String? ?? '');
    final codeController =
        TextEditingController(text: existing?['staff_code'] as String? ?? '');
    final targetController = TextEditingController(
        text: existing?['sales_target']?.toString() ?? '0');
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    final selected = ((existing?['permissions'] as List?) ?? [])
        .map((e) => e.toString())
        .toList();
    final selectedCats = ((existing?['assigned_categories'] as List?) ?? [])
        .map((e) => e.toString())
        .toList();
    bool isSuper = (existing?['is_super_admin'] as bool?) ?? false;
    // Super Admin rows always live in the ADMIN branch; new entries default
    // to the ADMIN branch, matching the pre-hierarchy behavior.
    String branch =
        (existing?['branch'] as String?) ?? (isSuper ? 'ADMIN' : 'ADMIN');
    final canSetSuper = _isCeo && existing == null;
    // The staff directory is already loaded (see _load), so a Staff ID that
    // collides with an existing row can be caught on the form. Both create
    // paths — the staff-create-gateway function and the create_staff RPC —
    // write straight into the staff_staff_code_key unique index with no
    // pre-check, which is what surfaced a raw "duplicate key value violates
    // unique constraint" after submit. Reads the live _staff on every call so
    // a reload that lands while the sheet is open is still respected.
    String? codeConflictMessage() {
      final row = findStaffCodeConflict(
        _staff,
        code: codeController.text,
        editingId: existing?['id']?.toString(),
      );
      if (row == null) return null;
      return kStaffCodeTakenHint(codeController.text, row['name']?.toString());
    }
    // Fresh sheet: never show a stale error/spinner from a previous attempt.
    _sheetError = null;
    _submitting = false;

    // UX: category checklist grouped by the category's own sector so the
    // CEO expands only the vehicle or service groups that are relevant.
    final vehicleCats =
        _categories.where((c) => c['sector'] == 'VEHICLE').toList();
    final serviceCats =
        _categories.where((c) => c['sector'] == 'SERVICE').toList();
    final otherCats = _categories
        .where((c) => c['sector'] != 'VEHICLE' && c['sector'] != 'SERVICE')
        .toList();

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
              20, 20, 20, MediaQuery.of(sheetContext).viewInsets.bottom + 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(existing == null ? 'Add staff' : 'Edit staff',
                    style: AppTheme.sectionHeader),
                const SizedBox(height: 16),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Full name *'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: codeController,
                  enabled: existing == null,
                  // The field claims the ID is unique, so say so while it is
                  // being typed rather than after submit — same pattern as the
                  // live password-length counter below.
                  onChanged: (_) => setSheetState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Staff ID *',
                    errorText:
                        existing == null ? codeConflictMessage() : null,
                    helperText: codeConflictMessage() == null
                        ? 'Unique, immutable'
                        : null,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: targetController,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Sales target (ETB)'),
                ),
                const SizedBox(height: 12),
                if (existing == null && _isCeo) ...[
                  const SizedBox(height: 4),
                  const Text('Gateway credentials (CEO only)',
                      style: AppTheme.sectionHeader),
                  const SizedBox(height: 8),
                  TextField(
                    controller: usernameController,
                    decoration: const InputDecoration(
                      labelText: 'Username or email *',
                      helperText: '3–32 characters; handed to staff offline',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    onChanged: (_) => setSheetState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Initial password *',
                      helperText: '10–200 characters; never shown again',
                    ),
                  ),
                  // Requirement + live counter so a too-short password is
                  // caught on the form, not as a server error after submit.
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Text(
                      'Minimum 10 characters'
                      '${passwordController.text.isEmpty ? '' : ' — ${passwordController.text.length}/200'}',
                      style: TextStyle(
                        fontSize: 11,
                        color: passwordController.text.isEmpty ||
                                passwordController.text.length >=
                                    kStaffPasswordMinLength
                            ? AppTheme.textMuted
                            : AppTheme.error,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: confirmPasswordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: 'Confirm password *',
                      errorText: confirmPasswordController.text.isEmpty ||
                              confirmPasswordController.text ==
                                  passwordController.text
                          ? null
                          : 'Passwords do not match',
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                // The other half of the "invalid username or password" report.
                // A staff row created by anyone other than the CEO has NO login
                // at all: only the CEO may mint gateway credentials
                // (create_staff_gateway raises ONLY_CEO_CAN_CREATE_STAFF_GATEWAY),
                // so this path writes a staff row and nothing else. The
                // credential fields above are simply hidden, which reads as
                // "there is no such thing" rather than "ask the CEO" — and the
                // person then tries to sign in and is refused forever.
                if (existing == null && !_isCeo)
                  Container(
                    margin: const EdgeInsets.only(top: 4, bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.warning.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: AppTheme.warning.withOpacity(0.4)),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline,
                            size: 18, color: AppTheme.warning),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'This staff member will have NO login. Only the '
                            'CEO can create gateway credentials — ask the CEO '
                            'to set a username and password, or link an '
                            'existing account from the staff menu.',
                            style: TextStyle(
                                fontSize: 12, color: AppTheme.textPrimary),
                          ),
                        ),
                      ],
                    ),
                  ),
                const Text('Branch', style: AppTheme.sectionHeader),
                const SizedBox(height: 4),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                        value: 'ADMIN',
                        label: Text('Admin'),
                        icon: Icon(Icons.admin_panel_settings_outlined,
                            size: 16)),
                    ButtonSegment(
                        value: 'ME',
                        label: Text('Me'),
                        icon: Icon(Icons.badge_outlined, size: 16)),
                  ],
                  selected: {branch},
                  onSelectionChanged: canSetSuper || existing == null
                      ? (sel) => setSheetState(() => branch = sel.first)
                      : null,
                ),
                const SizedBox(height: 4),
                Text(
                  'Sub-admins in "Me" are jointly managed by you and the '
                  'super admin. Sub-admins in "Admin" report to the super '
                  'admin.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                ),
                const SizedBox(height: 12),
                // UX: grouped collapsible sections replace the long flat
                // checklists — the CEO expands only what is relevant, and
                // each header shows how many options are selected.
                _CollapsibleSection(
                  icon: Icons.verified_user_outlined,
                  title: 'Permissions',
                  subtitle: 'What this staff member can do across the app.',                    countLabel: '${selected.length}/${_jobLabelsFrom(_jobCatalogue).length}',
                  initiallyExpanded: true,
                  trailing: [_AllNoneButtons(
                    onAll: () => setSheetState(() {
                      for (final key in _jobLabelsFrom(_jobCatalogue).keys) {
                        if (!selected.contains(key)) selected.add(key);
                      }
                    }),
                    onNone: () => setSheetState(() {
                      selected.removeWhere(_jobLabelsFrom(_jobCatalogue).containsKey);
                    }),
                  )],
                  children: [
                    for (final group in _jobGroupsFrom(_jobCatalogue)) ...[
                      Padding(
                        padding:
                            const EdgeInsets.only(left: 16, top: 6, bottom: 2),
                        child: Text(
                          group.key.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: AppTheme.teal,
                          ),
                        ),
                      ),
                      ...group.value.map(
                        (key) => CheckboxListTile(
                          dense: true,
                          title: Text(_jobLabelsFrom(_jobCatalogue)[key] ?? key,
                              style: const TextStyle(fontSize: 13)),
                          value: selected.contains(key),
                          onChanged: (on) => setSheetState(() {
                            on == true
                                ? selected.add(key)
                                : selected.remove(key);
                          }),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                const Text('Assigned categories',
                    style: AppTheme.sectionHeader),
                const SizedBox(height: 4),
                Text(
                  'Empty = unrestricted. Sub-admins only act inside their '
                  'categories. Expand a group to choose.',
                  style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                ),
                const SizedBox(height: 4),
                _categorySection(
                  sheetSet: setSheetState,
                  selectedCats: selectedCats,
                  title: 'Vehicle categories',
                  icon: Icons.directions_car_outlined,
                  cats: vehicleCats,
                ),
                _categorySection(
                  sheetSet: setSheetState,
                  selectedCats: selectedCats,
                  title: 'Service categories',
                  icon: Icons.room_service_outlined,
                  cats: serviceCats,
                ),
                if (otherCats.isNotEmpty)
                  _categorySection(
                    sheetSet: setSheetState,
                    selectedCats: selectedCats,
                    title: 'Other categories',
                    icon: Icons.category_outlined,
                    cats: otherCats,
                  ),
                if (canSetSuper) ...[
                  const SizedBox(height: 8),
                  _CollapsibleSection(
                    icon: Icons.shield_outlined,
                    title: 'Admin roles',
                    subtitle: 'Special roles above the permission system.',
                    countLabel: isSuper ? 'Super admin' : 'None',
                    initiallyExpanded: isSuper,
                    children: [
                      CheckboxListTile(
                        dense: true,
                        title: const Text('Super admin (runs the staff program)',
                            style: TextStyle(fontSize: 13)),
                        subtitle: const Text(
                            'ADMIN branch only; created by the CEO',
                            style: TextStyle(fontSize: 11)),
                        value: isSuper,
                        onChanged: (on) => setSheetState(() {
                          isSuper = on ?? false;
                          if (isSuper) branch = 'ADMIN';
                        }),
                      ),
                    ],
                  ),
                ],
                // In-sheet error banner — see _showSheetError. Without this
                // the operator sees nothing at all when submit fails.
                if (_sheetError != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withValues(alpha: 0.08),
                      border:
                          Border.all(color: AppTheme.error.withValues(alpha: 0.4)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline,
                            color: AppTheme.error, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _sheetError!,
                            style: const TextStyle(
                                fontSize: 12.5, color: AppTheme.error),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 16),
                PrimaryButton(
                  label: existing == null ? 'Create staff' : 'Save changes',
                  isLoading: _submitting,
                  onPressed: () async {
                    setSheetState(() => _sheetError = null);
                    if (nameController.text.trim().isEmpty ||
                        codeController.text.trim().isEmpty) {
                      _showSheetError(
                          setSheetState, 'Name and staff ID are required');
                      return;
                    }
                    // Staff ID rules apply to BOTH create paths, not just the
                    // CEO gateway one: an admin creating through the
                    // create_staff RPC would otherwise hit the same unique
                    // index and the same raw server message.
                    if (existing == null) {
                      final conflict = codeConflictMessage();
                      if (conflict != null) {
                        _showSheetError(setSheetState, conflict);
                        return;
                      }
                      if (!isValidStaffCode(codeController.text)) {
                        _showSheetError(
                          setSheetState,
                          'Staff ID must be $kStaffCodeMinLength–'
                          '$kStaffCodeMaxLength characters.',
                        );
                        return;
                      }
                    }
                    // Pre-submit validation mirrors staff-create-gateway so
                    // the operator never sees a raw server exception.
                    if (existing == null && _isCeo) {
                      final password = passwordController.text;
                      if (password.length < kStaffPasswordMinLength ||
                          password.length > kStaffPasswordMaxLength) {
                        _showSheetError(setSheetState,
                            'Password must be 10–200 characters.');
                        return;
                      }
                      if (password != confirmPasswordController.text) {
                        _showSheetError(
                            setSheetState, 'The passwords do not match.');
                        return;
                      }
                      final username =
                          usernameController.text.trim().toLowerCase();
                      if (!isValidStaffUsername(username)) {
                        _showSheetError(setSheetState, kStaffUsernameHint);
                        return;
                      }
                      if (nameController.text.trim().length < 2 ||
                          nameController.text.trim().length > 100) {
                        _showSheetError(setSheetState,
                            'Name must be 2–100 characters.');
                        return;
                      }
                      final salesTargetValue =
                          double.tryParse(targetController.text) ?? 0;
                      if (salesTargetValue < 0) {
                        _showSheetError(setSheetState,
                            'Sales target must be zero or a positive number.');
                        return;
                      }
                    }
                    setSheetState(() => _submitting = true);
                    try {
                      final client = Supabase.instance.client;
                      if (existing == null && _isCeo) {
                        const service = StaffAdminService();
                        await service.createGateway(
                          name: nameController.text.trim(),
                          staffCode: codeController.text.trim(),
                          username: usernameController.text,
                          password: passwordController.text,
                          confirmPassword: confirmPasswordController.text,
                          permissions: selected,
                          salesTarget:
                              double.tryParse(targetController.text) ?? 0,
                          isSuperAdmin: isSuper,
                          branch: isSuper ? 'ADMIN' : branch,
                          assignedCategories: selectedCats,
                        ).timeout(
                          const Duration(seconds: 25),
                          onTimeout: () => throw Exception(
                              'The request timed out. Check your connection '
                              'and try again.'),
                        );
                      } else if (existing == null) {
                        await client.rpc('create_staff', params: {
                          'p_name': nameController.text.trim(),
                          'p_staff_code': codeController.text.trim(),
                          'p_permissions': selected,
                          'p_sales_target':
                              double.tryParse(targetController.text) ?? 0,
                          'p_is_super_admin': isSuper,
                          'p_branch': isSuper ? 'ADMIN' : branch,
                          'p_assigned_categories': selectedCats,
                        }) as Map<String, dynamic>;
                      } else {
                        await client.rpc('update_staff', params: {
                          'p_staff_id': existing['id'],
                          'p_name': nameController.text.trim(),
                          'p_permissions': selected,
                          'p_sales_target':
                              double.tryParse(targetController.text) ?? 0,
                          'p_assigned_categories': selectedCats,
                        });
                      }
                      if (sheetContext.mounted)
                        Navigator.pop(sheetContext, true);
                    } catch (e) {
                      if (sheetContext.mounted) {
                        _showSheetError(
                          setSheetState,
                          e
                              .toString()
                              .replaceFirst('PostgrestException(', '')
                              .replaceFirst('Exception: ', ''),
                        );
                      }
                    } finally {
                      if (sheetContext.mounted) {
                        setSheetState(() => _submitting = false);
                      }
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result == true) _load();
  }

  /// Surface a failure INSIDE the editor sheet. A snackbar via
  /// ScaffoldMessenger renders on the Scaffold behind the modal bottom sheet
  /// and is invisible to the operator — which is exactly the silent "Create
  /// staff does nothing" bug. All editor feedback goes through this.
  void _showSheetError(
      void Function(void Function()) setSheetState, String message) {
    setSheetState(() {
      _sheetError = message;
      _submitting = false;
    });
  }

  /// One collapsible category group inside the editor (vehicle / service /
  /// other). The header always shows the selected count so the CEO can see
  /// state without expanding; the section reuses _CollapsibleSection.
  Widget _categorySection({
    required void Function(void Function()) sheetSet,
    required List<String> selectedCats,
    required String title,
    required IconData icon,
    required List<Map<String, dynamic>> cats,
  }) {
    final selectedInGroup =
        cats.where((c) => selectedCats.contains(c['id'])).length;
    return _CollapsibleSection(
      icon: icon,
      title: title,
      subtitle: cats.isEmpty
          ? 'No categories available in this group.'
          : '${cats.length} categories · subcategories indented.',
      countLabel: '$selectedInGroup/${cats.length}',
      initiallyExpanded: _expandedCategoryGroups.contains(title),
      onExpansionChanged: (expanded) =>
          expanded ? _expandedCategoryGroups.add(title) : _expandedCategoryGroups.remove(title),
      children: [
        for (final c in cats)
          CheckboxListTile(
            dense: true,
            contentPadding: c['parent_id'] != null
                ? const EdgeInsets.only(left: 28, right: 4)
                : const EdgeInsets.symmetric(horizontal: 4),
            title: Text(
              '${c['name']}',
              style: TextStyle(
                fontSize: c['parent_id'] != null ? 12 : 13,
                fontWeight: c['parent_id'] != null
                    ? FontWeight.w400
                    : FontWeight.w600,
              ),
            ),
            value: selectedCats.contains(c['id']),
            onChanged: (on) => sheetSet(() {
              on == true
                  ? selectedCats.add(c['id'] as String)
                  : selectedCats.remove(c['id']);
            }),
          ),
      ],
    );
  }

  /// Attach a staff record to a real account by email — the linked user
  /// then signs in and reaches the admin panel with the row's permissions.
  Future<void> _linkAccount(Map<String, dynamic> staff) async {
    final emailController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Link ${staff['name']} to an account'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'Enter the email of the account this staff member will sign '
                'in with. They must already be registered.'),
            const SizedBox(height: 12),
            TextField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email *'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Link')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final email = emailController.text.trim();
    if (email.isEmpty) return;
    try {
      await Supabase.instance.client.rpc('link_staff_user', params: {
        'p_staff_id': staff['id'],
        'p_email': email,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$email can now sign in as staff')));
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(
                content:
                    Text(friendlyError(e, context: 'Could not complete that action'))));
      }
    }
  }

  Future<void> _revoke(Map<String, dynamic> staff) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Revoke ${staff['name']}?'),
        content: const Text(
            'The staff member loses admin access and their staff entry is '
            'deactivated. History is kept.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Revoke')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Supabase.instance.client
          .rpc('revoke_staff', params: {'p_staff_id': staff['id']});
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(
                content:
                    Text(friendlyError(e, context: 'Could not complete that action'))));
      }
    }
  }

  /// Permanently remove a staff member.
  ///
  /// Behind a TYPED confirmation, not just a yes/no dialog: this destroys the
  /// auth account, so the username is freed for reuse and the history cannot
  /// be restored. Revoking (the menu item above) remains the default, safer
  /// action for "this person should not have access any more".
  Future<void> _deletePermanently(Map<String, dynamic> staff) async {
    final name = '${staff['name']}';
    final staffId = '${staff['id']}';

    final typed = await showDialog<String>(
      context: context,
      builder: (dialogContext) => TypedConfirmDialog(
        title: 'Delete $name permanently?',
        body: 'This removes their staff entry AND their login account. '
            'It cannot be undone, and their username becomes available again.\n\n'
            'To remove access without deleting, use Revoke instead.',
        confirmWord: 'DELETE',
        actionLabel: 'Delete forever',
      ),
    );
    if (typed != 'DELETE' || !mounted) return;

    try {
      await const StaffGatewayService().deletePermanently(staffId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$name deleted')),
      );
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not complete that action'))));
    }
  }

  /// Manage the job catalogue: add a job, retire one.
  ///
  /// Separate from the staff list on purpose. Adding a job is not editing a
  /// person, and putting it in the staff editor meant the only way to extend
  /// the catalogue was a migration — which is the same dead end as the CHECK
  /// constraint this replaced, one layer up.
  Future<void> _openJobManager() async {
    await showDialog<void>(
      context: context,
      builder: (_) => _JobManagerDialog(onChanged: _load),
    );
  }

  /// Sends a warning: reason + severity, in one dialog.
  ///
  /// The reason is required and cannot be a single character. A warning with
  /// no stated problem is indistinguishable from an insult, and it is the one
  /// thing the person on the receiving end cannot act on.
  Future<void> _sendWarning(Map<String, dynamic> staff) async {
    final name = '${staff['name']}';
    final reasonCtrl = TextEditingController();
    var severity = 'WARNING';
    String? validation;

    final sent = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('Warn $name?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                        value: 'WARNING',
                        label: Text('Warning'),
                        icon: Icon(Icons.warning_amber_rounded, size: 16)),
                    ButtonSegment(
                        value: 'SERIOUS',
                        label: Text('Serious'),
                        icon: Icon(Icons.report_problem_outlined, size: 16)),
                  ],
                  selected: {severity},
                  onSelectionChanged: (sel) =>
                      setDialogState(() => severity = sel.first),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: reasonCtrl,
                  maxLines: 3,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'What is the problem? *',
                    errorText: validation,
                    helperText: 'They see this word for word, with your name.',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                if (reasonCtrl.text.trim().length < 3) {
                  setDialogState(() =>
                      validation = 'Write at least a few words.');
                  return;
                }
                Navigator.pop(dialogContext, true);
              },
              style: FilledButton.styleFrom(
                backgroundColor: severity == 'SERIOUS'
                    ? AppTheme.error
                    : AppTheme.warning,
              ),
              child: const Text('Send warning'),
            ),
          ],
        ),
      ),
    );

    final reason = reasonCtrl.text.trim();
    reasonCtrl.dispose();
    if (sent != true || reason.length < 3 || !mounted) return;

    try {
      await const StaffGatewayService().warn(
        staffId: '${staff['id']}',
        reason: reason,
        severity: severity,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Warning sent to $name')),
      );
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            friendlyError(e, context: 'Could not send that warning'),
          ),
        ),
      );
    }
  }

  Future<void> _showPerformance(Map<String, dynamic> staff) async {    try {
      final client = Supabase.instance.client;
      final rows = await client
          .rpc('staff_performance', params: {'p_staff_id': staff['id']});
      final r = (rows as List).isNotEmpty
          ? rows.first as Map<String, dynamic>
          : <String, dynamic>{};
      final progressRows = await client.rpc(
        'staff_progress',
        params: {'p_staff_id': staff['id']},
      );
      final progress = (progressRows as List).isNotEmpty
          ? Map<String, dynamic>.from(progressRows.first as Map)
          : <String, dynamic>{};
      // Open-warning count, in the same dialog as the progress numbers. The
      // CEO's question is "is this person in trouble", and making them open a
      // separate screen to answer half of it is how a warning goes unread.
      var openWarnings = 0;
      try {
        final summary = await const StaffGatewayService().warningSummary();
        final row = summary.firstWhere(
          (r) => r['staff_id']?.toString() == staff['id']?.toString(),
          orElse: () => const {},
        );
        openWarnings = (row['open_warnings'] as num?)?.toInt() ?? 0;
      } catch (_) {
        // The performance numbers still stand on their own; a missing warning
        // count must not blank the dialog.
      }
      // Part 6 (migration 20261014000005): what this staff member actually
      // brought in — the providers they registered and the listings those
      // providers went on to post. Best-effort like the warning count above:
      // a database that has not run the migration still shows the rest of
      // the dialog.
      var providersRegistered = 0;
      var productsPosted = 0;
      try {
        final reg = await client.rpc('staff_registration_stats',
            params: {'p_staff_id': staff['id']});
        final regRow = (reg as List).isNotEmpty
            ? Map<String, dynamic>.from(reg.first as Map)
            : <String, dynamic>{};
        providersRegistered =
            (regRow['providers_registered'] as num?)?.toInt() ?? 0;
        productsPosted = (regRow['products_posted'] as num?)?.toInt() ?? 0;
      } catch (_) {
        // Migration pending — the other numbers still stand.
      }
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('${staff['name']} — performance'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Registrations approved: ${r['registrations'] ?? 0}'),
              // The registration oversight rows — same dialog, because "how
              // many providers did they bring in" is a performance question
              // and belongs beside the approvals count, not on another screen.
              Text('Providers registered: $providersRegistered'),
              Text('Listings those providers posted: $productsPosted'),
              Text('Sales total: ETB ${r['sales_total'] ?? 0}'),
              Text('Orders: ${r['orders_count'] ?? 0}'),
              Text('Rides: ${r['rides_count'] ?? 0}'),
              const SizedBox(height: 8),
              Text('Completed tasks: ${progress['completed_tasks'] ?? 0}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('Remaining tasks: ${progress['remaining_tasks'] ?? 0}'),
              Text('Task progress: ${progress['progress_percent'] ?? 0}%'),
              Text(
                  '30-day completed: ${progress['completed_last_30_days'] ?? 0}'),
              const SizedBox(height: 8),
              if (openWarnings > 0)
                Text(
                  'Open warnings: $openWarnings',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: openWarnings > 1
                        ? AppTheme.error
                        : AppTheme.warning,
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                'Target: ETB ${staff['sales_target'] ?? 0}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close')),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(
                content:
                    Text(friendlyError(e, context: 'Could not complete that action'))));
      }
    }
  }

  /// Read-only view of this staff member's CURRENT task queue — the CEO
  /// console half of staff_task_feed(p_staff_id), which the server already
  /// limits to CEO / Super Admin. From here one task can be removed
  /// (staff_cancel_task): a status change on the completion record, never a
  /// hard delete of the item or the person's history.
  Future<void> _showTasks(Map<String, dynamic> staff) async {
    List<Map<String, dynamic>> tasks;
    try {
      final client = Supabase.instance.client;
      final rows = await client
          .rpc('staff_task_feed', params: {'p_staff_id': staff['id']});
      tasks = (rows as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(friendlyError(e, context: 'Could not load this queue'))));
      return;
    }
    if (!mounted) return;

    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (sheetContext, setDialogState) => AlertDialog(
          title: Text('${staff['name']} — tasks'),
          content: SizedBox(
            width: double.maxFinite,
            height: 420,
            child: tasks.isEmpty
                ? const Center(
                    child: Text('No tasks in this queue',
                        style: TextStyle(color: AppTheme.textSecondary)),
                  )
                : ListView.separated(
                    itemCount: tasks.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final t = tasks[i];
                      final done = t['is_completed'] == true;
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          (t['title'] as String?) ?? 'Task',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          '${(t['description'] as String?) ?? ''}\n'
                          '${(t['status'] as String?) ?? ''} · '
                          '${(t['required_permission'] as String?) ?? ''}',
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: done
                            ? const Icon(Icons.check_circle_outline,
                                color: AppTheme.primaryGreen, size: 20)
                            : IconButton(
                                icon: const Icon(Icons.playlist_remove,
                                    color: AppTheme.error, size: 20),
                                tooltip: 'Remove from this queue',
                                onPressed: () async {
                                  final removed =
                                      await _cancelStaffTask(staff, t);
                                  if (removed) {
                                    setDialogState(() => tasks.removeAt(i));
                                  }
                                },
                              ),
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close')),
          ],
        ),
      ),
    );
  }

  /// This staff member's MOVEMENT history, read from `staff_activity_feed`.
  ///
  /// Separate from Performance on purpose. Performance answers "how many did
  /// they finish"; this answers "what have they been doing", which is the
  /// question a manager has about someone who looks idle, and the question an
  /// auditor has about a warning. Both existed as columns nobody could read.
  Future<void> _showMovement(Map<String, dynamic> staff) async {
    List<Map<String, dynamic>> entries;
    try {
      final rows = await Supabase.instance.client.rpc(
        'staff_activity_feed',
        params: {'p_staff_id': staff['id'], 'p_limit': 60},
      );
      entries = (rows as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              friendlyError(e, context: 'Could not load the movement log'))));
      return;
    }
    if (!mounted) return;

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${staff['name']} — movement'),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          // A scrollable, not a fixed column: this list is unbounded and a
          // Column of N children is the RenderFlex overflow again.
          child: entries.isEmpty
              ? const Center(
                  child: Text('No recorded movement yet',
                      style: TextStyle(color: AppTheme.textMuted)))
              : ListView.separated(
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final e = entries[i];
                    final when =
                        _relativeTime((e['created_at'] as String?) ?? '') ??
                            'unknown time';
                    final who = (e['actor_name'] as String?)?.trim();
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(_movementIcon(
                          (e['kind'] as String?) ?? (e['action'] as String?) ?? ''),
                          color: AppTheme.textMuted,
                          size: 18),
                      title: Text(
                        ((e['action'] as String?) ?? (e['kind'] as String?) ?? '')
                            .replaceAll('_', ' '),
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        [when, if (who != null && who.isNotEmpty) 'by $who']
                            .join(' · '),
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textMuted),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close')),
        ],
      ),
    );
  }

  /// Icon for a movement row. Unknown kinds get a neutral dot rather than a
  /// missing-glyph box, because the log table is written by many code paths
  /// and a new kind must not render as a tofu character.
  IconData _movementIcon(String kind, {Color? color, double size = 24}) {
    assert(size > 0);
    final k = kind.toLowerCase();
    if (k.contains('login') || k.contains('signin') || k.contains('sign_in')) {
      return Icons.login_outlined;
    }
    if (k.contains('logout') || k.contains('sign_out')) {
      return Icons.logout_outlined;
    }
    if (k.contains('creat') || k.contains('add')) {
      return Icons.person_add_alt_outlined;
    }
    if (k.contains('updat') || k.contains('edit') || k.contains('assign')) {
      return Icons.edit_outlined;
    }
    if (k.contains('delet') || k.contains('remov') || k.contains('revok')) {
      return Icons.delete_outline;
    }
    if (k.contains('warn')) return Icons.warning_amber_rounded;
    if (k.contains('approv') || k.contains('verif')) {
      return Icons.verified_outlined;
    }
    if (k.contains('pay') || k.contains('money')) {
      return Icons.payments_outlined;
    }
    return Icons.circle_outlined;
  }

  /// CEO-only confirmation for removing ONE task from a staff queue. The
  /// server (staff_cancel_task) re-checks the caller; the dialog exists so
  /// the click can carry a reason onto the audit record.
  Future<bool> _cancelStaffTask(
      Map<String, dynamic> staff, Map<String, dynamic> task) async {
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove this task?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '\"${(task['title'] as String?) ?? 'Task'}\" will leave '
              '${staff['name']}\'s queue. The underlying work item is '
              'unaffected and stays visible in the admin queues.',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                helperText: 'Stored on the cancellation record.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    final reason = reasonCtrl.text.trim();
    reasonCtrl.dispose();
    if (ok != true) return false;
    try {
      await Supabase.instance.client.rpc('staff_cancel_task', params: {
        'p_task_key': task['task_key'],
        'p_staff_id': staff['id'],
        'p_reason': reason.isEmpty ? null : reason,
      });
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(friendlyError(e, context: 'Could not remove this task'))));
      }
      return false;
    }
  }

  /// Only the CEO / Super Admin / owner may edit or revoke; the server
  /// enforces the same matrix via can_manage_staff.
  bool _canManage(Map<String, dynamic> s) {
    if (!_isCeo && !_isSuperAdmin) return false;
    if (s['is_ceo'] == true) return _isCeo; // only the CEO manages the CEO row
    return s['is_active'] == true;
  }

  // ── Task 8: referral-code manager ────────────────────────────────────────
  // Codes are issued per staff person (this screen); a person may hold
  // several. Each provider signup that uses a code records the person's
  // id + name on the provider row (see referral_tracking migration).
  Future<void> _showReferralCodes(Map<String, dynamic> staff) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _ReferralCodesSheet(staff: staff),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Roles & Staff'),
        actions: [
          // The job list is MANAGED, not fixed. Without this the only way to
          // add a job was to write a migration, so in practice the catalogue
          // was as frozen as the CHECK constraint it replaced.
          if (_isCeo || _isSuperAdmin)
            IconButton(
              tooltip: 'Manage jobs',
              onPressed: _openJobManager,
              icon: const Icon(Icons.work_outline),
            ),
        ],
      ),
      floatingActionButton: (_isCeo || _isSuperAdmin)
          ? FloatingActionButton.extended(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Add staff'),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ))
              : _staff.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.group_outlined,
                                size: 48, color: AppTheme.textMuted),
                            const SizedBox(height: 12),
                            const Text('No staff yet',
                                style: TextStyle(color: AppTheme.textMuted)),
                            const SizedBox(height: 8),
                            const Text(
                              'Ask the CEO or super admin to add staff members.',
                              style: TextStyle(
                                  fontSize: 12, color: AppTheme.textMuted),
                            ),
                          ],
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _staff.length,
                        itemBuilder: (_, i) {
                          final s = _staff[i];
                          final cats =
                              ((s['assigned_categories'] as List?) ?? [])
                                  .map((e) => e.toString())
                                  .toList();
                          final catNames = cats
                              .map((id) => _categories
                                  .where((c) => c['id'] == id)
                                  .map((c) => c['name'])
                                  .join(', '))
                              .where((n) => n.isNotEmpty)
                              .join(', ');
                          final city = _cityLabel(s);
                          final obligations = _obligationLabels(s);
                          final movement = _movementLabel(s);
                          final openWarnings =
                              (_rosterFor(s)['open_warnings'] as num?)?.toInt() ??
                                  0;
                          return Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: ListTile(
                              // Tapping the row opens the editor. The ⋮ menu
                              // already had an Edit item, but burying the only
                              // way to change someone's roles behind a
                              // three-dot menu is why "I can create staff but
                              // not manage them" reads as a missing feature.
                              onTap: _canManage(s) ? () => _openEditor(s) : null,
                              leading: Icon(
                                s['is_active'] == true
                                    ? _branchIcon(s)
                                    : Icons.block_outlined,
                                color: s['is_active'] == true
                                    ? AppTheme.primaryGreen
                                    : AppTheme.error,
                              ),
                              title: Text('${s['name']}'
                                  '  ·  ${s['staff_code']}'),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Rank and branch on one line, so "who outranks
                                  // whom" is readable without opening anyone.
                                  Text('${_branchLabel(s)}'
                                      '  ·  ${_rankLabel(s)}',
                                      style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: AppTheme.teal)),
                                  // The city SCOPE. Absent chip means unscoped
                                  // (every city) and is labelled as such rather
                                  // than left blank, because a blank chip and a
                                  // chip that failed to load look identical.
                                  Row(
                                    children: [
                                      const Icon(Icons.place_outlined,
                                          size: 12, color: AppTheme.textMuted),
                                      const SizedBox(width: 2),
                                      Expanded(
                                        child: Text(
                                          city ?? 'All cities',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: city == null
                                                ? AppTheme.textMuted
                                                : null,
                                          ),
                                        ),
                                      ),
                                      if (openWarnings > 0)
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                                Icons.warning_amber_rounded,
                                                size: 12,
                                                color: AppTheme.error),
                                            const SizedBox(width: 2),
                                            Text('$openWarnings',
                                                style: const TextStyle(
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w700,
                                                    color: AppTheme.error)),
                                          ],
                                        ),
                                    ],
                                  ),
                                  Text(
                                    obligations.isEmpty
                                        ? 'No permissions'
                                        : obligations.join(', '),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (catNames.isNotEmpty)
                                    Text('Categories: $catNames',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 11)),
                                  if (movement != null)
                                    Text(movement,
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: AppTheme.textMuted)),
                                ],
                              ),
                              // No isThreeLine: the subtitle is a variable
                              // number of lines (rank, city, obligations,
                              // categories, movement), and pinning the tile to
                              // three lines is what produced the RenderFlex
                              // overflow this screen already had once.
                              trailing: PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'edit') _openEditor(s);
                                  if (v == 'perf') _showPerformance(s);
                                  if (v == 'tasks') _showTasks(s);
                                  if (v == 'movement') _showMovement(s);
                                  if (v == 'referrals') _showReferralCodes(s);
                                  if (v == 'revoke') _revoke(s);
                                  if (v == 'delete') _deletePermanently(s);
                                  if (v == 'link') _linkAccount(s);
                                  if (v == 'warn') _sendWarning(s);
                                },
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                      value: 'perf',
                                      child: Text('Performance')),
                                  // The MOVEMENT history. The counters on the
                                  // card say "3 done, 2h ago"; this answers
                                  // "doing WHAT", which is the question a
                                  // manager actually has about an absent or
                                  // under-performing member.
                                  if (_isCeo || _isSuperAdmin)
                                    const PopupMenuItem(
                                        value: 'movement',
                                        child: Text('Movement log')),
                                  // The CEO's cross-staff console: read any
                                  // staff member's CURRENT queue through the
                                  // same RPC the staff workspace uses, and
                                  // remove a single task from it. The server
                                  // refuses both for anyone who is not CEO /
                                  // Super Admin; hiding the item is UX, not
                                  // the boundary.
                                  if (_isCeo || _isSuperAdmin)
                                    const PopupMenuItem(
                                        value: 'tasks',
                                        child: Text('Tasks')),
                                  // The step between "tell them off" and
                                  // "take their access away". Revoke already
                                  // existed; nothing in between did, so a
                                  // manager whose only options were silence
                                  // or revocation had neither.
                                  if (_canManage(s) && s['is_ceo'] != true)
                                    const PopupMenuItem(
                                        value: 'warn',
                                        child: Text('Send warning')),
                                  const PopupMenuItem(
                                      value: 'referrals',
                                      child: Text('Referral codes')),
                                  if (_canManage(s) && s['user_id'] == null)
                                    const PopupMenuItem(
                                        value: 'link',
                                        child: Text('Link account')),
                                  if (_canManage(s))
                                    const PopupMenuItem(
                                        value: 'edit', child: Text('Edit')),
                                  if (_canManage(s))
                                    const PopupMenuItem(
                                        value: 'revoke', child: Text('Revoke')),
                                  // Never offered for the CEO row: the server
                                  // refuses it too, but hiding an action that
                                  // would always fail is better UX.
                                  if (_canManage(s) && s['is_ceo'] != true)
                                    const PopupMenuItem(
                                      value: 'delete',
                                      child: Text('Delete permanently',
                                          style: TextStyle(
                                              color: AppTheme.error)),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}

/// A confirmation the user has to finish by typing [confirmWord].
///
/// Public (rather than private to this file) so the overflow regression test
/// can drive the real widget. A test against a copy of the layout would not
/// catch the layout regressing.

///
/// Used for irreversible actions where a stray tap must not be enough. The
/// dialog pops with the typed word, so the caller can compare it against what
/// it expects — a cancelled dialog returns null.
class TypedConfirmDialog extends StatefulWidget {
  const TypedConfirmDialog({
    required this.title,
    required this.body,
    required this.confirmWord,
    required this.actionLabel,
  });

  final String title;
  final String body;
  final String confirmWord;
  final String actionLabel;

  @override
  State<TypedConfirmDialog> createState() => TypedConfirmDialogState();
}

class TypedConfirmDialogState extends State<TypedConfirmDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _controller.text.trim().toUpperCase() == widget.confirmWord;
    return AlertDialog(
      // `scrollable: true` makes the DIALOG ITSELF scroll its content.
      // `isScrollControlled: true` at the showDialog call site is not enough
      // on its own: it only relaxes the height cap, and the title plus a
      // paragraph plus a TextField still exceeded it at a 1.8–2.0 text scale
      // ("BOTTOM OVERFLOWED BY 31 PIXELS", then by 101 and 216). Making it a
      // property of the widget rather than of the call site means no caller
      // can forget it.
      scrollable: true,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.body,
              style: const TextStyle(
                  fontSize: 14, color: AppTheme.textSecondary)),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: 'Type ${widget.confirmWord} to confirm',
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          // Disabled until the word matches, so the destructive action is
          // never one stray tap away.
          onPressed: ready ? () => Navigator.pop(context, _controller.text.trim().toUpperCase()) : null,
          style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}

/// Manages the job catalogue itself: add a job, retire a job.
///
/// This exists because "the job must be selectable, not fixed" is only half
/// true if the set of jobs is still whatever a migration last seeded. Until
/// this dialog shipped, picking a job was easy and CHOOSING WHICH jobs exist
/// still required a deploy — the catalogue was frozen one layer up from the
/// CHECK constraint 20260927000034 removed.
///
/// Retired jobs stay listed (greyed, with their holder count) rather than
/// disappearing. A list that silently drops what it retired is how a job
/// someone still remembers comes back as a duplicate months later.
class _JobManagerDialog extends StatefulWidget {
  final VoidCallback onChanged;
  const _JobManagerDialog({required this.onChanged});

  @override
  State<_JobManagerDialog> createState() => _JobManagerDialogState();
}

class _JobManagerDialogState extends State<_JobManagerDialog> {
  List<Map<String, dynamic>> _jobs = const [];
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await const StaffGatewayService().allJobs();
      if (!mounted) return;
      setState(() {
        _jobs = rows;
        _loading = false;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = friendlyError(e, context: 'Could not load the job list');
      });
    }
  }

  void _toast(String message, {bool bad = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        backgroundColor: bad ? AppTheme.error : null,
      ));
  }

  Future<void> _create() async {
    final labelCtrl = TextEditingController();
    final groupCtrl = TextEditingController(text: 'General');
    final descCtrl = TextEditingController();

    // The form returns its values instead of writing to fields on this State:
    // a dialog popped and rebuilt mid-save would otherwise lose them.
    final entered = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New job'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: labelCtrl,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Job name',
                  helperText: 'The server derives a safe key from this.',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: groupCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Group',
                  helperText: 'Sorts the checklist in the staff editor.',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descCtrl,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'What it covers'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final label = labelCtrl.text.trim();
              if (label.length < 2) return;
              Navigator.pop(dialogContext, {
                'label': label,
                'group': groupCtrl.text.trim(),
                'description': descCtrl.text.trim(),
              });
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );

    labelCtrl.dispose();
    groupCtrl.dispose();
    descCtrl.dispose();

    if (entered == null) return;
    final label = entered['label'] ?? '';
    if (label.isEmpty) return;

    setState(() => _loading = true);
    try {
      await const StaffGatewayService().createJob(
        label: label,
        group: entered['group'],
        description: entered['description'],
      );
      _toast('"$label" added to the job list');
      widget.onChanged();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _toast(friendlyError(e, context: 'Could not add that job'), bad: true);
    }
  }

  Future<void> _retire(Map<String, dynamic> job) async {
    final holders = (job['holders'] as num?)?.toInt() ?? 0;
    // Checked here as well as server-side. The server refuses either way, but
    // being refused for something the screen just showed you is a worse
    // experience than being told before you tap.
    if (holders > 0) {
      _toast('$holders staff member${holders == 1 ? '' : 's'} still hold '
          '"${job['label']}". Remove it from them first.', bad: true);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Retire "${job['label']}"?'),
        content: const Text(
          'It will no longer be offered when assigning jobs. The record of '
          'who held it is kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Retire'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _loading = true);
    try {
      await const StaffGatewayService().retireJob('${job['key']}');
      _toast('"${job['label']}" retired');
      widget.onChanged();
      await _load();
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      _toast(friendlyError(e, context: 'Could not retire that job'), bad: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _jobs.where((j) => j['is_active'] == true).toList();
    final retired = _jobs.where((j) => j['is_active'] != true).toList();

    return AlertDialog(
      title: const Text('Job catalogue'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Jobs are chosen here, not fixed in the app. Add one and it is '
              'immediately assignable.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Flexible(
              child: _loading
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: CircularProgressIndicator(),
                      ),
                    )
                  : _loadError != null
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(_loadError!),
                        )
                      : ListView(
                          shrinkWrap: true,
                          children: [
                            for (final job in active) _jobTile(job),
                            if (retired.isNotEmpty) ...[
                              const Divider(height: 24),
                              Padding(
                                padding:
                                    const EdgeInsets.only(bottom: 8, left: 4),
                                child: Text(
                                  'RETIRED',
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelSmall
                                      ?.copyWith(letterSpacing: 1.2),
                                ),
                              ),
                              for (final job in retired) _jobTile(job),
                            ],
                          ],
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        FilledButton.icon(
          onPressed: _loading ? null : _create,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('New job'),
        ),
      ],
    );
  }

  Widget _jobTile(Map<String, dynamic> job) {
    final isActive = job['is_active'] == true;
    final holders = (job['holders'] as num?)?.toInt() ?? 0;
    final description = '${job['description'] ?? ''}';
    final group = '${job['group_name'] ?? ''}';

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        isActive ? Icons.work_outline : Icons.work_off_outlined,
        color: isActive ? null : Theme.of(context).disabledColor,
      ),
      title: Text(
        '${job['label']}',
        style: TextStyle(
          color: isActive ? null : Theme.of(context).disabledColor,
        ),
      ),
      subtitle: Text(
        [
          if (group.isNotEmpty) group,
          if (description.isNotEmpty) description,
          '$holders holding',
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: isActive
          ? TextButton(
              onPressed: _loading ? null : () => _retire(job),
              child: const Text('Retire'),
            )
          : null,
    );
  }
}

/// UX: a single collapsible card used by the staff editor. The header row
/// (icon + title + selected-count chip + chevron) toggles the body, so long
/// checklists stay collapsed until the CEO expands the group they need.
class _CollapsibleSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  /// Selection summary shown in a small chip on the header (e.g. "2/9").
  final String? countLabel;

  /// Header-right action buttons (e.g. All / None). Rendered before the
  /// chevron; keep them compact.
  final List<Widget> trailing;
  final List<Widget> children;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onExpansionChanged;

  const _CollapsibleSection({
    required this.icon,
    required this.title,
    this.subtitle,
    this.countLabel,
    this.trailing = const [],
    required this.children,
    this.initiallyExpanded = false,
    this.onExpansionChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Theme(
      // Remove the default divider so stacked sections read as one group.
      data: Theme.of(context).copyWith(
        dividerColor: Colors.transparent,
      ),
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        clipBehavior: Clip.antiAlias,
        child: Theme(
          data: Theme.of(context).copyWith(
            expansionTileTheme: Theme.of(context).expansionTileTheme.copyWith(
                  backgroundColor: Theme.of(context).cardColor,
                  collapsedBackgroundColor: Theme.of(context).cardColor,
                  shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                  collapsedShape:
                      const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
                ),
          ),
          child: ExpansionTile(
            initiallyExpanded: initiallyExpanded,
            onExpansionChanged: onExpansionChanged,
            tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            childrenPadding:
                const EdgeInsets.only(left: 8, right: 8, bottom: 8),
            leading: Icon(icon, color: AppTheme.teal, size: 22),
            title: Text(title,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700)),
            subtitle: subtitle == null
                ? null
                : Text(subtitle!,
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...trailing,
                if (countLabel != null)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryGreen.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      countLabel!,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primaryGreen,
                      ),
                    ),
                  ),
                const Icon(Icons.expand_more, size: 20),
              ],
            ),
            children: children,
          ),
        ),
      ),
    );
  }
}

/// Header-right All / None shortcuts for the permissions section.
class _AllNoneButtons extends StatelessWidget {
  final VoidCallback onAll;
  final VoidCallback onNone;
  const _AllNoneButtons({required this.onAll, required this.onNone});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      TextButton(
        onPressed: onAll,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
          textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
        child: const Text('All'),
      ),
      TextButton(
        onPressed: onNone,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
          textStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        ),
        child: const Text('None'),
      ),
    ]);
  }
}

/// Task 8: per-staff referral-code sheet — lists the person's codes with
/// usage counts, issues new ones, and toggles active state. Deletion is
/// omitted from the sheet (registrations keep the denormalized name, but an
/// accidental delete would orphan future lookups); use deactivate instead.
class _ReferralCodesSheet extends StatefulWidget {
  final Map<String, dynamic> staff;
  const _ReferralCodesSheet({required this.staff});
  @override
  State<_ReferralCodesSheet> createState() => _ReferralCodesSheetState();
}

class _ReferralCodesSheetState extends State<_ReferralCodesSheet> {
  List<Map<String, dynamic>> _codes = [];
  bool _loading = true;
  String? _error;

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
      final rows = await Supabase.instance.client.rpc('admin_referral_codes');
      _codes = (rows as List)
          .whereType<Map<String, dynamic>>()
          .where((r) => r['staff_id'] == widget.staff['id'])
          .toList();
    } catch (e) {
      _error = friendlyError(e, context: 'Could not load staff');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _issue() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('New code for ${widget.staff['name']}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Code',
            hintText: 'letters, digits, . _ - only',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Issue')),
        ],
      ),
    );
    if (ok != true) return;
    final code = controller.text.trim();
    if (code.isEmpty) return;
    try {
      await Supabase.instance.client.rpc('admin_issue_referral_code', params: {
        'p_staff_id': widget.staff['id'],
        'p_code': code,
      });
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() => _error = friendlyError(e, context: 'Could not load staff'));
      }
    }
  }

  Future<void> _toggle(Map<String, dynamic> code) async {
    try {
      await Supabase.instance.client
          .rpc('admin_set_referral_code_active', params: {
        'p_code_id': code['id'],
        'p_active': !(code['is_active'] == true),
      });
      await _load();
    } catch (e) {
      if (mounted)
        setState(
            () => _error = friendlyError(e, context: 'Could not load staff'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Referral codes — ${widget.staff['name']} '
                    '(${widget.staff['staff_code']})',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Providers who sign up with a code are attributed to '
              '${widget.staff['name']} in Registration History.',
              style: AppTheme.caption,
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Text(_error!,
                  style: const TextStyle(color: AppTheme.error, fontSize: 12))
            else if (_codes.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No codes issued yet.',
                    style: TextStyle(color: AppTheme.textMuted)),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _codes.length,
                  itemBuilder: (_, i) {
                    final c = _codes[i];
                    final active = c['is_active'] == true;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        title: Text('${c['code']}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(
                          'used ${c['uses'] ?? 0} · ${active ? 'active' : 'inactive'}',
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: Switch(
                          value: active,
                          onChanged: (_) => _toggle(c),
                        ),
                      ),
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _issue,
                icon: const Icon(Icons.add),
                label: const Text('Issue new code'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
