import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/primary_button.dart';

/// Reached from the admin sidebar as "Categories".
///
/// The tree, and the door that grows it. Before this screen there was no way
/// to add a category from inside the app at all: the table has always had a
/// `parent_id`, but the only writes were migrations, so "we need a category
/// for this trade" meant a deploy — and the administrator who was asked the
/// question could not answer it.
///
/// Every write goes through `admin_create_category`, a definer RPC that
/// re-checks `is_admin()` and refuses a mother category that is not top level.
/// This screen is navigation and form-filling, not authority: a staff member
/// who reaches it without the permission gets the server's refusal, not a
/// silent no-op.
class AdminCategoriesScreen extends StatefulWidget {
  const AdminCategoriesScreen({super.key});

  @override
  State<AdminCategoriesScreen> createState() => _AdminCategoriesScreenState();
}

class _AdminCategoriesScreenState extends State<AdminCategoriesScreen> {
  List<Map<String, dynamic>> _topLevel = const [];
  Map<String, List<Map<String, dynamic>>> _childrenByParent = const {};
  bool _loading = true;
  bool _busy = false;
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
      final rows = await Supabase.instance.client
          .from('categories')
          .select('id, name, slug, sector, marketplace_sector, parent_id, '
              'is_active, sort_order')
          .order('sort_order')
          .order('name');

      final all = List<Map<String, dynamic>>.from(rows as List);
      final top = all.where((c) => c['parent_id'] == null).toList();
      final byParent = <String, List<Map<String, dynamic>>>{};
      for (final row in all) {
        final parent = row['parent_id'];
        if (parent is! String) continue;
        byParent.putIfAbsent(parent, () => []).add(row);
      }
      if (!mounted) return;
      setState(() {
        _topLevel = top;
        _childrenByParent = byParent;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load categories');
      });
    }
  }

  /// The add form's mother list. Only TOP-LEVEL rows, because that is the only
  /// thing the server accepts — offering a sub-category here would be a form
  /// that is guaranteed to be refused.
  List<Map<String, dynamic>> get _mothers =>
      _topLevel.where((c) => c['is_active'] == true).toList();

  Future<void> _add() async {
    final mothers = _mothers;
    if (mothers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('There is no top-level category to add one under yet')));
      return;
    }
    final draft = await showDialog<_CategoryDraft>(
      context: context,
      builder: (_) => _AddCategoryDialog(mothers: mothers),
    );
    if (draft == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final created = await Supabase.instance.client.rpc(
        'admin_create_category',
        params: {
          'p_parent_id': draft.motherId,
          'p_name': draft.name,
          'p_description': draft.description,
        },
      );
      final rows = (created as List);
      final row = rows.isEmpty ? null : rows.first;
      final slug = row is Map ? (row['slug'] as String?) : null;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(slug == null
              ? 'Category added'
              : 'Category added · /${draft.name.toLowerCase().replaceAll(' ', '-')} ($slug)')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(friendlyError(e, context: 'Could not add that category'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Categories'),
        backgroundColor: AppTheme.primaryGreen,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Reload',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _add,
        backgroundColor: AppTheme.primaryGreen,
        foregroundColor: Colors.white,
        icon: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.add_rounded),
        label: const Text('Add category'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : _topLevel.isEmpty
                  ? const _EmptyTree()
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                      itemCount: _topLevel.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (_, i) => _motherCard(_topLevel[i]),
                    ),
    );
  }

  Widget _motherCard(Map<String, dynamic> mother) {
    final id = (mother['id'] ?? '') as String;
    final children = _childrenByParent[id] ?? const <Map<String, dynamic>>[];
    final sector = ((mother['sector'] as String?) ?? '').trim();
    final market = ((mother['marketplace_sector'] as String?) ?? '').trim();
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.folder_open_rounded,
                  size: 18, color: AppTheme.primaryGreen),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  (mother['name'] as String?) ?? '',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700),
                ),
              ),
              if (market.isNotEmpty)
                _tag(market, AppTheme.primaryGreen),
            ],
          ),
          if (sector.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 2),
              child: Text(
                'top level · $sector',
                style: const TextStyle(
                    fontSize: 11.5, color: AppTheme.textMuted),
              ),
            ),
          if (children.isEmpty)
            const Padding(
              padding: EdgeInsets.only(left: 26, top: 8),
              child: Text(
                'No sub-categories yet. Add one with the button below.',
                style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final child in children) _tagChip(child),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _tagChip(Map<String, dynamic> child) {
    final inactive = child['is_active'] != true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: inactive ? AppTheme.textMuted : AppTheme.cardBorder,
        ),
      ),
      child: Text(
        (child['name'] as String?) ?? '',
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: inactive ? AppTheme.textMuted : AppTheme.textPrimary,
        ),
      ),
    );
  }

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: color),
        ),
      );
}

class _EmptyTree extends StatelessWidget {
  const _EmptyTree();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'No categories yet.',
          style: TextStyle(fontSize: 14, color: AppTheme.textMuted),
        ),
      ),
    );
  }
}

/// What the admin typed, before the server has seen it.
class _CategoryDraft {
  const _CategoryDraft({required this.motherId, required this.name, this.description});
  final String motherId;
  final String name;
  final String? description;
}

class _AddCategoryDialog extends StatefulWidget {
  const _AddCategoryDialog({required this.mothers});
  final List<Map<String, dynamic>> mothers;

  @override
  State<_AddCategoryDialog> createState() => _AddCategoryDialogState();
}

class _AddCategoryDialogState extends State<_AddCategoryDialog> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  String? _motherId;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a category'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              value: _motherId,
              decoration: const InputDecoration(
                labelText: 'Mother category',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: [
                for (final mother in widget.mothers)
                  DropdownMenuItem<String>(
                    value: (mother['id'] ?? '') as String,
                    child: Text((mother['name'] as String?) ?? ''),
                  ),
              ],
              onChanged: (value) => setState(() => _motherId = value),
            ),
            const SizedBox(height: 14),
            BirrTextField(
              controller: _nameController,
              label: 'Name',
              hint: 'e.g. Pet Grooming',
            ),
            const SizedBox(height: 14),
            BirrTextField(
              controller: _descriptionController,
              label: 'Description (optional)',
              hint: 'What belongs in this category',
              maxLines: 2,
            ),
            const SizedBox(height: 12),
            const Text(
              'The new category takes its mother\'s sector and price model — '
              'you are placing it in a trade, not opening a new one.',
              style: TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        PrimaryButton(
          label: 'Add category',
          onPressed: (_motherId == null || _nameController.text.trim().isEmpty)
              ? null
              : () => Navigator.of(context).pop(_CategoryDraft(
                    motherId: _motherId!,
                    name: _nameController.text.trim(),
                    description: _descriptionController.text.trim().isEmpty
                        ? null
                        : _descriptionController.text.trim(),
                  )),
        ),
      ],
    );
  }
}
