import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers/auth_provider.dart';
// AppFailure is not re-exported by safe_call.dart, so it must be imported
// directly to catch it — catching it by type is what keeps the friendly
// message on screen instead of a raw PostgREST string.
import '../../core/resilience/app_failure.dart';
import '../../core/resilience/failure_mapper.dart';
import '../../core/resilience/safe_call.dart';
import '../../core/theme/app_theme.dart';

/// The CEO workspace: Staff, Finance, Data and Other.
///
/// ABOVE the admin role, not a replacement for it. A CEO account also holds
/// ADMIN, so every `/admin/*` screen stays reachable; this adds the views a
/// regular admin has no business seeing (company payroll, every city's
/// finances, every payment screenshot) and the one act nobody else may
/// perform (deleting an admin).
///
/// WHAT THIS SCREEN DELIBERATELY DOES NOT DO
/// -----------------------------------------
/// It does not re-implement the 24 admin screens. Fee editing already exists at
/// `/admin/fees`, expenses at `/admin/expenses`, the audit log at
/// `/admin/history`. The Other section LINKS to them rather than growing a
/// second copy that can drift from the first — the brief asked for these to be
/// surfaced here, and a link surfaces them without forking them.
///
/// This screen is also not a security boundary. Every query behind it runs
/// under RLS/RPC checks that re-derive the caller's CEO status server-side
/// (`is_ceo()`), and a Dart gate is only ever a way to avoid showing a button
/// that will be refused.
class CeoDashboard extends ConsumerStatefulWidget {
  const CeoDashboard({super.key});

  @override
  ConsumerState<CeoDashboard> createState() => _CeoDashboardState();
}

class _CeoDashboardState extends ConsumerState<CeoDashboard>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  bool _loading = true;
  String? _error;

  Map<String, dynamic>? _payroll;
  Map<String, dynamic>? _finance;
  List<Map<String, dynamic>> _appeals = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;

      // Each read goes through safeCall so a failure is an AppFailure with a
      // plain message rather than a raw driver string, and so one slow query
      // cannot hang the screen past its deadline.
      final payroll = await safeCall<dynamic>(
        () => client.rpc('ceo_payroll_report'),
        context: 'CEO payroll',
      );
      final finance = await safeCall<dynamic>(
        () => client.rpc('ceo_city_finance'),
        context: 'CEO finance',
      );
      final appeals = await safeCall<List<dynamic>>(
        () => client
            .from('appeal_cases')
            .select('id,user_id,description,phone,email,status,'
                'resolution_note,resolved_at,photo_path,created_at')
            .order('created_at', ascending: false)
            .limit(200),
        context: 'appeal cases',
      );

      if (!mounted) return;
      setState(() {
        _payroll = payroll is Map ? Map<String, dynamic>.from(payroll) : null;
        _finance = finance is Map ? Map<String, dynamic>.from(finance) : null;
        _appeals = appeals
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList(growable: false);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // The message comes from the mapper, never from the exception: a raw
      // PostgrestException is not something to put in front of a CEO.
      setState(() {
        _loading = false;
        _error = e is Exception && e.toString().isNotEmpty
            ? _plain(e)
            : 'Could not load the CEO data.';
      });
    }
  }

  /// A plain sentence from the shared mapper — never the exception verbatim.
  ///
  /// This used to pull `message: …` out of the exception's toString() with a
  /// regex, which happily extracted `permission denied for table …` — exactly
  /// the schema detail the mapper exists to keep off a screen. An
  /// [AppFailure] keeps the classification a service layer made; anything
  /// else is re-derived and given the action's context.
  String _plain(Object e) {
    return AppFailureMapper.map(e, context: 'Could not load the CEO data')
        .message;
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    // Server-side is the real gate; this only avoids rendering a workspace that
    // would come back empty or refused. `canOpenCeoOnly` accepts the server's
    // own answer as well as the local heuristic, so a CEO whose authority the
    // database grants through a staff row flagged is_ceo is not told here that
    // the workspace is not theirs — which is what made the danger-zone
    // "Delete an account" card a dead end.
    if (!auth.canOpenCeoOnly) {
      return Scaffold(
        appBar: AppBar(title: const Text('CEO')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'This workspace is for the CEO account only.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('CEO'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: const [
            Tab(text: 'Staff'),
            Tab(text: 'Finance'),
            Tab(text: 'Data'),
            Tab(text: 'Other'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorState(message: _error!, onRetry: _load)
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _StaffSection(payroll: _payroll, onChanged: _load),
                    _FinanceSection(finance: _finance),
                    _DataSection(appeals: _appeals, finance: _finance),
                    const _OtherSection(),
                  ],
                ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Staff — City -> staff list -> individual, with payroll at all three levels
// ─────────────────────────────────────────────────────────────────────────────
class _StaffSection extends StatelessWidget {
  final Map<String, dynamic>? payroll;
  final Future<void> Function() onChanged;

  const _StaffSection({required this.payroll, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    if (payroll == null) {
      return const _Empty('No payroll data. The CEO payroll report returned '
          'nothing — run Deploy Supabase if migration 69 has not applied.');
    }

    final cities = (payroll!['by_city'] as List?) ?? const [];
    final staff = (payroll!['by_staff'] as List?) ?? const [];
    final missing = (payroll!['staff_without_salary'] as num?)?.toInt() ?? 0;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // The team controls, first, because this is the section a CEO opens
        // to act rather than to read. Every row lands on a screen that already
        // existed and already worked; nothing is re-implemented here, so there
        // is no second copy of "create a staff member" to drift out of step.
        const _SectionTitle('Manage the team'),
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.person_add_alt_1),
                title: const Text('Create or edit a staff member'),
                subtitle: const Text(
                    'Name, staff ID, city, salary, job role and permissions.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/admin/staff'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.assignment_ind_outlined),
                title: const Text('Assign a role or task to a user'),
                subtitle: const Text(
                    'Give a user a staff role, scope it to categories, warn '
                    'them, or remove the role.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/admin/staff-assignment'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.fact_check_outlined),
                title: const Text('Audit log'),
                subtitle: const Text(
                    'Every staff and admin action, append-only — how you check '
                    'who actually did the work.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/admin/history'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const _SectionTitle('Payroll'),
        _MoneyCard(
          label: 'Total monthly payroll (whole company)',
          value: payroll!['company_monthly_payroll_birr'],
          footnote: '${payroll!['active_staff'] ?? 0} active staff',
        ),
        if (missing > 0)
          // Said out loud, not hidden: a total that silently omits someone
          // with no salary entered looks correct and underpays the forecast.
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '$missing active staff have no salary on record, so they are '
              'not in the total above.',
              style: const TextStyle(fontSize: 12, color: AppTheme.error),
            ),
          ),
        const SizedBox(height: 20),
        const _SectionTitle('By city'),
        if (cities.isEmpty)
          const _Empty('No staff are assigned to a city yet. Set a city on a '
              'staff record to see city subtotals.')
        else
          ...cities.map((c) {
            final row = Map<String, dynamic>.from(c as Map);
            final cityName = row['city'] ?? 'Unassigned';
            final cityStaff = staff
                .map((s) => Map<String, dynamic>.from(s as Map))
                .where((s) => (s['city'] ?? 'Unassigned') == cityName)
                .toList();
            return ExpansionTile(
              title: Text('$cityName'),
              subtitle: Text(
                '${row['headcount'] ?? 0} staff · '
                '${_birr(row['monthly_payroll_birr'])} / month',
              ),
              children: [
                if (cityStaff.isEmpty)
                  const _Empty('No staff rows for this city.')
                else
                  ...cityStaff.map(
                      (s) => _StaffTile(staff: s, onChanged: onChanged)),
              ],
            );
          }),
      ],
    );
  }
}

class _StaffTile extends StatefulWidget {
  final Map<String, dynamic> staff;
  final VoidCallback onChanged;

  const _StaffTile({required this.staff, required this.onChanged});

  @override
  State<_StaffTile> createState() => _StaffTileState();
}

class _StaffTileState extends State<_StaffTile> {
  bool _saving = false;

  Map<String, dynamic> get staff => widget.staff;

  /// City and salary live on the staff row, but the staff form does not
  /// collect them — so without this, the City -> staff drill-down and every
  /// city payroll subtotal would stay permanently empty. Editable here rather
  /// than in the form because the form writes through the CEO-gated staff
  /// creation RPC, and adding parameters there means restating a SECURITY
  /// DEFINER function full of hierarchy guards.
  Future<void> _editTerms() async {
    final cityController =
        TextEditingController(text: (staff['city'] as String?) ?? '');
    final salaryController = TextEditingController(
        text: ((staff['salary_birr'] as num?)?.toDouble() ?? 0)
            .toStringAsFixed(0));
    final roleController =
        TextEditingController(text: (staff['job_role'] as String?) ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${staff['name'] ?? 'Staff'} · ${staff['staff_code'] ?? '—'}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: cityController,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'City',
                    helperText: 'Drives city payroll and the drill-down'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: roleController,
                decoration: const InputDecoration(labelText: 'Job role'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: salaryController,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Monthly salary (ETB)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (saved != true || !mounted) return;

    final salary = double.tryParse(salaryController.text.trim());
    if (salary != null && salary < 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('A salary cannot be negative.')));
      return;
    }

    // safeCall throws rather than returning a result object, so the failure
    // path is a catch. The guard is not retried: it is a single idempotent
    // write, and re-sending a salary change because the reply was slow would
    // log a second audit row for one edit.
    setState(() => _saving = true);
    try {
      await safeCall<int>(
        () async {
          await Supabase.instance.client.rpc('ceo_set_staff_terms', params: {
            'p_staff_id': staff['id'],
            'p_city': cityController.text.trim(),
            'p_salary_birr': salary,
            'p_job_role': roleController.text.trim(),
          });
          return 0;
        },
        context: 'Set staff terms',
      );
    } on AppFailure catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save. Try again.')));
      return;
    }

    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved. Payroll updated.')));
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final salary = (staff['salary_birr'] as num?)?.toDouble() ?? 0;
    final tasks = (staff['tasks_this_month'] as num?)?.toInt() ?? 0;
    final warnings = (staff['warnings_this_month'] as num?)?.toInt() ?? 0;
    final active = staff['is_active'] == true;

    return ListTile(
      dense: true,
      title: Text('${staff['name'] ?? 'Unnamed'} · ${staff['staff_code'] ?? '—'}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${staff['job_role'] ?? 'Staff'}'
              '${active ? '' : ' · inactive'}'
              '${(staff['city'] as String?)?.isNotEmpty == true ? ' · ${staff['city']}' : ' · no city set'}'),
          const SizedBox(height: 2),
          // Performance from real logged actions: staff_task_completions and
          // staff_warnings. Not a computed score, because a score nobody can
          // trace back to an action is not usable in a staffing decision.
          Text(
            '$tasks tasks completed this month · $warnings warnings',
            style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_birr(salary),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          if (_saving)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            IconButton(
              tooltip: 'Set city, role and salary',
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: _editTerms,
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Finance — city-scoped and company-wide, computed independently
// ─────────────────────────────────────────────────────────────────────────────
class _FinanceSection extends StatelessWidget {
  final Map<String, dynamic>? finance;

  const _FinanceSection({required this.finance});

  @override
  Widget build(BuildContext context) {
    if (finance == null) {
      return const _Empty('No finance data. Run Deploy Supabase if migration '
          '69 has not applied.');
    }

    final company = Map<String, dynamic>.from(
        (finance!['company'] as Map?) ?? const {});
    final cities = (finance!['by_city'] as List?) ?? const [];
    final unattributed =
        (company['unattributed_wallet_balance_birr'] as num?)?.toDouble() ?? 0;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _SectionTitle('Company-wide (all cities)'),
        _MoneyCard(
          label: 'Provider wallet balances held',
          value: company['wallet_balances_birr'],
        ),
        _MoneyCard(
          label: 'Fees collected (from the ledger)',
          value: company['fees_collected_birr'],
        ),
        _MoneyCard(
          label: 'Gross transaction volume',
          value: company['gross_volume_birr'],
        ),
        _MoneyCard(
          label: 'Monthly payroll (all cities)',
          value: company['monthly_payroll_birr'],
        ),
        _MoneyCard(
          label: 'Fees minus payroll',
          value: company['net_after_payroll_birr'],
          emphasise: true,
        ),
        _MoneyCard(
          label: 'Pending recharge requests',
          value: company['pending_recharges'],
          isCount: true,
        ),
        if (unattributed.abs() > 0.01)
          // Reported rather than left for the reader to notice. Money in a
          // wallet whose provider has no city is still real money, and a city
          // breakdown that silently omits it would understate the total.
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${_birr(unattributed)} of wallet balance is not attributed to '
              'any city (providers with no city set).',
              style: const TextStyle(fontSize: 12, color: AppTheme.error),
            ),
          ),
        const SizedBox(height: 20),
        const _SectionTitle('By city (each computed on its own)'),
        if (cities.isEmpty)
          const _Empty('No city-scoped finance yet.')
        else
          ...cities.map((c) => _CityFinanceCard(city: Map<String, dynamic>.from(c as Map))),
        const SizedBox(height: 24),
        const _SectionTitle('Fees and charges'),
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: const Icon(Icons.tune, color: AppTheme.primaryGreen),
            title: const Text('Fees: on/off and amounts'),
            subtitle: const Text(
                'Switch each charge on or off and edit what it costs, in one '
                'editor, with the audit trail of who changed what.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/admin/fees'),
          ),
        ),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.receipt_long, color: AppTheme.primaryGreen),
            title: const Text('Expenses'),
            subtitle: const Text('Register, review and total company expenses.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/admin/expenses'),
          ),
        ),
      ],
    );
  }
}

class _CityFinanceCard extends StatelessWidget {
  final Map<String, dynamic> city;

  const _CityFinanceCard({required this.city});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${city['city'] ?? 'Unassigned'}',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 8),
            _kv('Wallet balances', _birr(city['wallet_balances_birr'])),
            _kv('Fees collected', _birr(city['fees_collected_birr'])),
            _kv('Gross volume', _birr(city['gross_volume_birr'])),
            _kv('Monthly payroll', _birr(city['monthly_payroll_birr'])),
            _kv('Fees minus payroll', _birr(city['net_after_payroll_birr']),
                strong: true),
            _kv('Pending recharges', '${city['pending_recharges'] ?? 0}'),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v, {bool strong = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            Text(v,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: strong ? FontWeight.w800 : FontWeight.w600)),
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Data — appeals, resolutions, payment screenshots
// ─────────────────────────────────────────────────────────────────────────────
class _DataSection extends StatelessWidget {
  final List<Map<String, dynamic>> appeals;
  final Map<String, dynamic>? finance;

  const _DataSection({required this.appeals, required this.finance});

  @override
  Widget build(BuildContext context) {
    final proofs = (finance?['pending_recharge_proofs'] as List?) ?? const [];
    final open = appeals.where((a) => a['status'] == 'OPEN').length;
    final resolved = appeals.length - open;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _SectionTitle('Appeal cases'),
        Text('$open open · $resolved resolved / closed',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 8),
        if (appeals.isEmpty)
          const _Empty('No appeal cases filed yet.')
        else
          ...appeals.take(50).map((a) => _AppealTile(appeal: a)),
        const SizedBox(height: 24),
        const _SectionTitle('Payment screenshots awaiting review'),
        if (proofs.isEmpty)
          const _Empty('No recharge proofs are pending review.')
        else
          ...proofs.map((p) => _ProofTile(proof: Map<String, dynamic>.from(p as Map))),
        const SizedBox(height: 24),
        const _SectionTitle('Admin activity log'),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.history, color: AppTheme.primaryGreen),
            title: const Text('Audit log'),
            subtitle: const Text(
                'Every admin action, including account deletions, with who did '
                'it and when.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/admin/history'),
          ),
        ),
      ],
    );
  }
}

class _AppealTile extends StatelessWidget {
  final Map<String, dynamic> appeal;

  const _AppealTile({required this.appeal});

  @override
  Widget build(BuildContext context) {
    final status = appeal['status'] as String? ?? 'OPEN';
    final color = status == 'OPEN' ? AppTheme.gold : AppTheme.primaryGreen;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(status,
                      style: TextStyle(fontSize: 11, color: color,
                          fontWeight: FontWeight.w700)),
                ),
                const Spacer(),
                if (appeal['photo_path'] != null)
                  const Icon(Icons.image_outlined, size: 16,
                      color: AppTheme.textMuted),
              ],
            ),
            const SizedBox(height: 6),
            Text('${appeal['description'] ?? ''}',
                maxLines: 3, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 4),
            Text('${appeal['phone'] ?? ''}'
                '${(appeal['email'] as String?)?.isNotEmpty == true ? ' · ${appeal['email']}' : ''}',
                style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
            // The resolution is the record of the decision. Shown inline so the
            // CEO sees the outcome next to the case rather than having to open
            // it to find out whether anyone dealt with it.
            if ((appeal['resolution_note'] as String?)?.isNotEmpty == true)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Resolution: ${appeal['resolution_note']}',
                    style: const TextStyle(fontSize: 12, color: AppTheme.primaryGreen)),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProofTile extends StatelessWidget {
  final Map<String, dynamic> proof;

  const _ProofTile({required this.proof});

  @override
  Widget build(BuildContext context) {
    final path = proof['screenshot_path'] as String?;
    // Bucket and method both match what admin_payment_verification_screen.dart
    // already does for these exact objects: 'payment-screenshots' via
    // getPublicUrl. Recharge proofs live in payment-screenshots, NOT
    // payment-proofs -- that one holds order payment proofs, and reading the
    // wrong bucket returns a URL that 404s on every row.
    //
    // Access is governed by the bucket's storage policies, not by this call.
    final url = path == null
        ? null
        : Supabase.instance.client.storage
            .from('payment-screenshots')
            .getPublicUrl(path);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: url == null
            ? const Icon(Icons.receipt_long, color: AppTheme.textMuted)
            : ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(url, width: 44, height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(
                        Icons.broken_image_outlined, color: AppTheme.textMuted)),
              ),
        title: Text('${_birr(proof['amount_birr'])} · ${proof['city'] ?? 'Unassigned'}'),
        subtitle: Text('${proof['payment_reference'] ?? 'no reference'}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/admin/payments'),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Other — the catch-all, and the one act nobody else may perform
// ─────────────────────────────────────────────────────────────────────────────
/// ConsumerWidget rather than StatelessWidget because the account block added
/// below signs out through authProvider, which is what the rest of the app
/// does -- calling Supabase.instance.client.auth.signOut() here instead would
/// skip whatever cleanup the provider performs and leave a second, divergent
/// sign-out path in the product.
class _OtherSection extends ConsumerWidget {
  const _OtherSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _SectionTitle('Admin surfaces reachable from here'),
        // Linked, not duplicated. These already exist; a second copy would
        // drift from the original and the CEO would be looking at whichever
        // one they happened to open.
        ...const [
          ('/admin/users', 'Users', 'Every account, with its roles and status.'),
          ('/admin/providers', 'Providers', 'Provider applications and profiles.'),
          ('/admin/approvals', 'Approvals', 'Everything waiting on a decision.'),
          ('/admin/payments', 'Payment verification', 'Recharge and order proofs.'),
          ('/admin/appeals', 'Appeals', 'Review and resolve appeal cases.'),
          ('/admin/support-tickets', 'Support tickets', 'Chat escalations from the assistant.'),
          ('/admin/disputes', 'Disputes', 'Contested orders and payments.'),
          ('/admin/expenses', 'Expenses', 'Register and review company expenses.'),
          ('/admin/history', 'Audit log', 'Every admin action, append-only.'),
          ('/admin/staff', 'Staff assignment', 'Staff records and permissions.'),
          ('/admin/settings', 'Settings', 'System-wide configuration.'),
          ('/admin/roles/permissions', 'Role permissions', 'Who may do what.'),
        ].map((e) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(e.$2),
                subtitle: Text(e.$3),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(e.$1),
              ),
            )),
        const SizedBox(height: 24),
        const _SectionTitle('Your account'),
        // The CEO dashboard is a SEPARATE surface from the admin one, and it
        // had neither of these. The admin app bar carries a "Change password"
        // item in its avatar popup, but nothing on THIS screen reached it, so
        // the most privileged account in the product had the least obvious way
        // to change its own password -- and no way to sign out of the surface
        // at all. Both link out rather than reimplementing: the screen and the
        // Edge Function already exist and already work.
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: const Icon(Icons.lock_outline,
                color: AppTheme.primaryGreenDark),
            title: const Text('Change password'),
            subtitle: const Text(
                'Your current password, then a new one. Every other device is '
                'signed out afterwards.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/account/password'),
          ),
        ),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.logout, color: AppTheme.error),
            title: const Text('Sign out'),
            subtitle: const Text('End this session on this device.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => ref.read(authProvider.notifier).signOut(),
          ),
        ),
        const SizedBox(height: 24),
        const _SectionTitle('Danger zone'),
        Card(
          margin: EdgeInsets.zero,
          color: AppTheme.error.withValues(alpha: 0.06),
          child: ListTile(
            leading: const Icon(Icons.gpp_maybe, color: AppTheme.error),
            title: const Text('Delete an account'),
            subtitle: const Text(
                'The full directory: every user, provider and staff account, '
                'each with a delete action that runs through the shared '
                'deletion cascade. CEO only, recorded with your reason.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/admin/accounts'),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared bits
// ─────────────────────────────────────────────────────────────────────────────
class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(text,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      );
}

class _MoneyCard extends StatelessWidget {
  final String label;
  final Object? value;
  final String? footnote;
  final bool emphasise;
  final bool isCount;

  const _MoneyCard({
    required this.label,
    required this.value,
    this.footnote,
    this.emphasise = false,
    this.isCount = false,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary)),
                  const SizedBox(height: 4),
                  Text(
                    isCount ? '${value ?? 0}' : _birr(value),
                    style: TextStyle(
                      fontSize: emphasise ? 20 : 17,
                      fontWeight: FontWeight.w800,
                      color: emphasise ? AppTheme.primaryGreen : AppTheme.textPrimary,
                    ),
                  ),
                  if (footnote != null)
                    Text(footnote!,
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.textMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;

  const _Empty(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(text,
            style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      );
}

class _ErrorState extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 40, color: AppTheme.textMuted),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      );
}

/// Birr formatting, with thousands separators so a payroll total is readable
/// at a glance rather than a run of digits.
String _birr(Object? v) {
  final n = v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
  final s = n.toStringAsFixed(0);
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return '${buf.toString()} birr';
}
