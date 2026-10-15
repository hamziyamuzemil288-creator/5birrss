import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/services/posting_gate.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/photo_grid.dart';

class ProviderProductListScreen extends StatefulWidget {
  const ProviderProductListScreen({super.key});
  @override
  State<ProviderProductListScreen> createState() => _State();
}

class _State extends State<ProviderProductListScreen> {
  List<Map<String, dynamic>> _products = [];
  bool _loading = true;
  String? _error;
  String? _providerId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;
      final prov = await client
          .from('provider_profiles')
          .select('id')
          .eq('user_id', userId)
          .maybeSingle();
      if (prov == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      _providerId = prov['id'];
      final data = await client
          .from('products')
          .select('*, product_images(id,storage_path,sort_order)')
          .eq('provider_id', _providerId!)
          .order('created_at', ascending: false);
      if (mounted) {
        setState(() {
          _products = List<Map<String, dynamic>>.from(data as List);
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load this page');
        });
      }
    }
  }

  /// Whether this listing is visible to buyers. `products.is_active` is the
  /// flag every public read already filters on, so this switch and the home
  /// feed cannot disagree.
  bool _isVisible(Map<String, dynamic> p) => p['is_active'] != false;

  /// Hide or show one listing, by the same flag the public reads use.
  Future<void> _setVisibility(String id, bool visible) async {
    try {
      final res = await Supabase.instance.client.rpc(
        'provider_set_product_visibility',
        params: {'p_product_id': id, 'p_visible': visible},
      );
      if (!mounted) return;
      final message = res is Map ? res['message'] as String? : null;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message ??
            (visible
                ? 'Buyers can see this listing again.'
                : 'Buyers can no longer see this listing.')),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(friendlyError(e,
                context: 'Could not change who can see this'))));
      }
    }
  }

  /// Delete — or, when the listing has order history, hide it instead.
  ///
  /// The dialog says which one is about to happen where it can be known, but
  /// the RULE is the server's: `provider_delete_product` counts the order
  /// lines and only really deletes when there are none, and the `order_items`
  /// foreign key (NO ACTION) refuses a hard delete that would rewrite order
  /// history whatever a client asks for. So the confirm dialog is a
  /// courtesy, and the answer shown afterwards is what actually happened.
  Future<void> _delete(String id, bool visible) async {
    if (visible) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Delete this listing?'),
          content: const Text(
              'If it has never been ordered, it and its photos are removed for '
              'good.\n\nIf it appears in any past order, it is HIDDEN instead '
              '— buyers stop seeing it, and your order history stays intact.\n\n'
              'To take it off sale without deleting anything, use Hide.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete',
                    style: TextStyle(color: AppTheme.error))),
          ],
        ),
      );
      if (confirm != true) return;
    }

    try {
      final res = await Supabase.instance.client.rpc(
        'provider_delete_product',
        params: {'p_product_id': id},
      );
      if (!mounted) return;
      final action = res is Map ? res['action'] as String? : null;
      final message = res is Map ? res['message'] as String? : null;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(message ??
            (action == 'hidden'
                ? 'This listing has order history, so it was hidden instead of '
                    'deleted.'
                : 'The listing and its photos are gone.')),
        duration: const Duration(seconds: 5),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(friendlyError(e, context: 'Could not delete that'))));
      }
    }
  }

  /// Add Product, gated exactly like the header's "Post product" button and
  /// the dashboard's Add Product action: the server's fulfilment blockers
  /// decide, and anyone short of the document/wallet minimum gets the
  /// two-step checklist that re-checks itself as they finish each step.
  Future<void> _startAddProduct() async {
    final providerId = _providerId;
    if (providerId == null || !mounted) return;
    final allowed =
        await PostingGate.instance.ensure(context, providerId: providerId);
    if (!allowed || !mounted) return;
    await context.push('/provider/products/new');
  }

  Future<void> _toggleAvailability(String id, bool current) async {
    try {
      await Supabase.instance.client
          .from('products')
          .update({'is_available': !current}).eq('id', id);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not complete that action'))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Products')),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppTheme.primaryGreen,
        onPressed: _startAddProduct,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : _products.isEmpty
              ? Center(
                  child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.inventory_2_outlined,
                        size: 64, color: AppTheme.textMuted),
                    const SizedBox(height: 16),
                    const Text('No products yet',
                        style: TextStyle(color: AppTheme.textMuted)),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _startAddProduct,
                      icon: const Icon(Icons.add),
                      label: const Text('Add Product'),
                    ),
                  ],
                ))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _products.length,
                    itemBuilder: (_, i) {
                      final p = _products[i];
                      final images = (p['product_images'] as List?) ?? const [];
                      return Card(
                        child: ListTile(
                          // The real listing photo, not a grey box: a provider
                          // scanning their own catalogue is looking for "which
                          // one has the photo I uploaded". The +N badge says
                          // how many more there are without turning a list row
                          // into a grid.
                          leading: SizedBox(
                            width: 48,
                            height: 48,
                            child: images.isEmpty
                                ? Container(
                                    decoration: BoxDecoration(
                                        color: AppTheme.creamDark,
                                        borderRadius:
                                            BorderRadius.circular(8)),
                                    child: const Icon(
                                        Icons.inventory_2_outlined,
                                        color: AppTheme.textMuted),
                                  )
                                : Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      PhotoGrid(
                                        crossAxisCount: 1,
                                        spacing: 0,
                                        borderRadius: 8,
                                        items: [
                                          PhotoGridItem.stored(
                                            images.first['storage_path']
                                                as String? ?? '',
                                            bucket: 'product-images',
                                          ),
                                        ],
                                      ),
                                      if (images.length > 1)
                                        Positioned(
                                          right: 2,
                                          bottom: 2,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 4, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: Colors.black
                                                  .withOpacity(0.6),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              '+${images.length - 1}',
                                              style: const TextStyle(
                                                fontSize: 10,
                                                color: Colors.white,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                          ),
                          title: Text(p['name'] ?? '',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Row(
                            children: [
                              Text(
                                  '${p['price']} ${p['currency'] ?? 'ETB'}',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.primaryGreen,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: (p['is_available'] ?? true)
                                      ? AppTheme.success.withOpacity(0.1)
                                      : AppTheme.error.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                    (p['is_available'] ?? true)
                                        ? 'Available'
                                        : 'Unavailable',
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: (p['is_available'] ?? true)
                                            ? AppTheme.success
                                            : AppTheme.error)),
                              ),
                              // A hidden listing says so on the provider's own
                              // list: it is invisible to buyers, and it must
                              // not look identical to a live one here.
                              if (!_isVisible(p)) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppTheme.textMuted.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text('Hidden',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: AppTheme.textMuted)),
                                ),
                              ],
                            ],
                          ),
                          // The two controls, both on the row rather than
                          // buried in a submenu: a labelled switch for "can
                          // buyers see this" and a delete that says what it
                          // will do.
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Switch(
                                    value: _isVisible(p),
                                    activeThumbColor: AppTheme.primaryGreen,
                                    onChanged: (v) =>
                                        _setVisibility(p['id'], v),
                                  ),
                                  Text(_isVisible(p) ? 'Visible' : 'Hidden',
                                      style: const TextStyle(
                                          fontSize: 9,
                                          color: AppTheme.textMuted)),
                                ],
                              ),
                              PopupMenuButton(
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                      value: 'edit', child: Text('Edit')),
                                  PopupMenuItem(
                                    value: 'visibility',
                                    child: Text(_isVisible(p)
                                        ? 'Hide from buyers'
                                        : 'Show to buyers'),
                                  ),
                                  PopupMenuItem(
                                    value: 'toggle',
                                    child: Text((p['is_available'] ?? true)
                                        ? 'Mark Unavailable'
                                        : 'Mark Available'),
                                  ),
                                  const PopupMenuItem(
                                      value: 'delete',
                                      child: Text('Delete',
                                          style: TextStyle(
                                              color: AppTheme.error))),
                                ],
                                onSelected: (v) {
                                  if (v == 'edit') {
                                    context
                                        .push('/provider/products/${p['id']}');
                                  } else if (v == 'visibility') {
                                    _setVisibility(p['id'], !_isVisible(p));
                                  } else if (v == 'toggle') {
                                    _toggleAvailability(
                                        p['id'], p['is_available'] ?? true);
                                  } else if (v == 'delete') {
                                    _delete(p['id'], _isVisible(p));
                                  }
                                },
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
