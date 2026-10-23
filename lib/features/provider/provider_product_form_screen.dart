import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/provider_readiness.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/city_service.dart';
import '../../core/services/location_service.dart';
import '../../core/services/provider_activation_service.dart';
import '../../core/services/provider_doc_gate.dart';
import '../../core/services/app_update_service.dart';
import '../../core/services/fee_resolver.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/utils/friendly_failure.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/photo_grid.dart';

class ProviderProductFormScreen extends StatefulWidget {
  final String? productId;
  const ProviderProductFormScreen({super.key, this.productId});
  @override
  State<ProviderProductFormScreen> createState() => _State();
}

class _State extends State<ProviderProductFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _priceCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }
  // Listing pricing mode: fixed price (default) or per-unit (kg / liter).
  // Unit mode keeps the existing full listing (images optional) and stores
  // the per-unit price in `price` AND `price_per_unit`, plus `unit`.
  bool _unitMode = false;
  String _unit = 'KG'; // 'KG' | 'LTR'
  String? _categoryId;
  bool _isAvailable = true;

  /// Where this listing is based. Null means "all cities", which is both
  /// the default for a new listing and the honest answer for a provider who
  /// does not care: `products.city` is nullable and the home feed's own
  /// query treats null as "show it in every city", so an unset city can
  /// never hide a listing from Fresh Finds. Chosen from the same list the
  /// city picker uses, so the value written here and the value the feed
  /// filters on cannot drift.
  String? _city;

  /// Whether a buyer must wait for this provider to confirm availability
  /// before payment details are shown. Persisted on
  /// `products.requires_availability_confirmation`; absent from a database
  /// that has not run migration 20260927000074, in which case it reads false
  /// and saving it is skipped.
  bool _requiresAvailabilityConfirmation = false;
  List<Map<String, dynamic>> _categories = [];
  List<File> _newImages = [];
  List<Map<String, dynamic>> _existingImages = [];
  String? _providerId;
  bool _loading = true;
  String? _error;
  // One-time activation gate: providers must pay the registration fee via
  // their first wallet recharge before uploading listings.
  bool _registrationFeePaid = true;
  String _activationMessage = '';
  bool _saving = false;
  // Item H: the listing fee and the product commission, resolved by the SAME
  // readers the charge uses (fee_product_listing_fee, fee_commission_percent)
  // and shown inline, so a provider sees the cost before publishing instead of
  // discovering it in the wallet. Null until loaded; "unavailable" when the
  // reader could not be reached.
  FeeQuote? _listingFeeQuote;
  FeeQuote? _commissionQuote;
  final _picker = ImagePicker();

  // Listing GPS: defaults from the business profile; can be re-captured.
  double? _lat;
  double? _lng;
  bool _capturingGps = false;

  bool get _isEdit => widget.productId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Item H: resolve the listing fee and product commission through the shared
  /// [FeeResolver] so the numbers on this form are the numbers the charge
  /// uses. Resolved against the selected category (falling back to the
  /// provider's own) and the provider's city — the same context the charge
  /// reads — so changing the category re-quotes rather than showing a stale
  /// fee.
  Future<void> _loadFeePreview(String providerId) async {
    final ctx = await FeeResolver.instance.providerContext(providerId);
    final categoryId = _categoryId ?? ctx.categoryId;
    final listing = await FeeResolver.instance
        .listingFee(categoryId: categoryId, city: ctx.city);
    final commission = await FeeResolver.instance.commissionPercent(
      categoryId: categoryId,
      city: ctx.city,
      isProduct: true,
    );
    if (!mounted) return;
    setState(() {
      _listingFeeQuote = listing;
      _commissionQuote = commission;
    });
  }

  Future<void> _load() async {
    // Clear any previous failure so a successful retry actually recovers.
    if (mounted && _error != null) setState(() => _error = null);
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;
      // Activation gate (non-fatal: form stays usable if the check fails).
      try {
        final activation = await ProviderActivation.load();
        if (activation != null && !activation.isActivated) {
          if (mounted) {
            setState(() {
              _registrationFeePaid = false;
              _activationMessage = activation.blockingMessage;
            });
          }
        }
      } catch (_) {}
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
      // Item H: the fees this listing will be charged, best-effort. A failure
      // leaves the preview hidden — it must never block the form.
      try {
        await _loadFeePreview(prov['id'] as String);
      } catch (_) {}
      // Prime the listing location from the business profile GPS.
      final fullProv = await client
          .from('provider_profiles')
          .select('location_lat, location_lng')
          .eq('user_id', userId)
          .maybeSingle();
      _lat = (fullProv?['location_lat'] as num?)?.toDouble();
      _lng = (fullProv?['location_lng'] as num?)?.toDouble();
      final cats = await client
          .from('categories')
          .select('id,name')
          .eq('sector', 'SERVICE')
          .eq('is_active', true)
          .isFilter('parent_id', null)
          .order('name');
      var categories = List<Map<String, dynamic>>.from(cats as List);
      // Fallback: if no parent categories exist, show all categories
      // for this sector so the dropdown is never empty.
      if (categories.isEmpty) {
        final allCats = await client
            .from('categories')
            .select('id,name')
            .eq('sector', 'SERVICE')
            .eq('is_active', true)
            .order('name');
        categories = List<Map<String, dynamic>>.from(allCats as List);
      }
      _categories = categories;

      if (_isEdit) {
        final prod = await client
            .from('products')
            .select('*, product_images(*)')
            .eq('id', widget.productId!)
            .single();
        _nameCtrl.text = prod['name'] ?? '';
        _descCtrl.text = prod['description'] ?? '';
        _priceCtrl.text = '${prod['price'] ?? ''}';
        _qtyCtrl.text = '${prod['quantity'] ?? ''}';
        _categoryId = prod['category_id'];
        _isAvailable = prod['is_available'] ?? true;
        _city = prod['city'] as String?;
        _requiresAvailabilityConfirmation =
            prod['requires_availability_confirmation'] ?? false;
        final unit = prod['unit'] as String?;
        _unitMode = unit != null;
        if (unit == 'LTR') _unit = 'LTR';
        if (_unitMode) {
          final ppu = (prod['price_per_unit'] as num?)?.toDouble();
          if (ppu != null && ppu > 0) _priceCtrl.text = _fmt(ppu);
        }
        final prodLoc = GeoPoint.parse(prod['location']);
        if (prodLoc != null) {
          _lat = prodLoc.lat;
          _lng = prodLoc.lng;
        }
        _existingImages = List<Map<String, dynamic>>.from(
            (prod['product_images'] as List?) ?? []);
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load the form');
        });
      }
    }
  }

  Future<void> _pickImages() async {
    // Downscaled, not forwarded — `product-images` has a 5MB limit and
    // imageQuality alone re-encodes at full resolution.
    final picked = await _picker.pickMultiImage(
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked.isNotEmpty) {
      setState(() {
        _newImages.addAll(picked.map((x) => File(x.path)));
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_providerId == null) {
      // This used to be a bare `return`. The form looks complete, the profile
      // row every write is scoped to could not be read, and no listing, no
      // photo and no error were produced — which is what a provider experiences
      // as "the Save button does nothing". A refused save has to say so.
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'Your provider profile could not be loaded, so nothing was saved. '
          'Pull to refresh, then try again.',
        ),
        backgroundColor: AppTheme.error,
        duration: Duration(seconds: 4),
      ));
      return;
    }
    // Task 7, narrowed by Part 1 of the registration rework (migration
    // 20261014000001): document verification is VOLUNTARY for a
    // SERVICE_PROVIDER and must not block posting a product. The only
    // authority on whether documents block THIS provider is the server's own
    // answer — provider_fulfilment_blockers(), the same function
    // create_provider_product consults — so that is what is asked, instead of
    // the sheet being shown unconditionally (which held every self-service
    // provider at "Nothing was saved" for a document the server does not
    // require). A VEHICLE_PROVIDER still gets the sheet exactly as before:
    // the ride flow was deliberately untouched and the server still raises
    // DOCUMENTS_UNVERIFIED for them. An unreadable answer fails OPEN, the
    // same as ProviderDocGate always has — the create RPC still enforces the
    // rule server-side and its refusal reaches showPublishBlockedDialog.
    var documentsBlocked = false;
    try {
      final blockers = await Supabase.instance.client.rpc(
        'provider_fulfilment_blockers',
        params: {'p_provider_id': _providerId},
      );
      documentsBlocked = blockers is List &&
          blockers.any((b) => b.toString() == 'DOCUMENTS_UNVERIFIED');
    } catch (_) {
      // Unreadable → treated as not blocked here; the server still decides.
    }
    if (documentsBlocked) {
      final documentsOk =
          await ProviderDocGate.instance.ensureDocuments(context);
      if (!documentsOk) {
        // The gate returns false when its sheet is dismissed with "Later",
        // and this branch used to return silently too: the provider tapped
        // SAVE, the dialog closed, and no listing and no photo were uploaded
        // with no message at all. Nothing was saved, so say nothing was
        // saved.
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
            'Nothing was saved. Verify your identity to upload listings and '
            'photos.',
          ),
          backgroundColor: AppTheme.error,
          duration: Duration(seconds: 4),
        ));
        return;
      }
    }
    // Block uploads until the one-time registration fee is paid.
    if (!_registrationFeePaid) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_activationMessage),
        backgroundColor: AppTheme.error,
        duration: const Duration(seconds: 4),
      ));
      return;
    }    // A listing without a location cannot be found by proximity search:
    // search_products computes distance_km only when p.location is set, and
    // its ST_DWithin predicate short-circuits on `p.location IS NULL`, so the
    // radius filter never even runs. Every location-less listing is therefore
    // returned to every nearby searcher regardless of distance — the source
    // of the "unfamiliar place name" results.
    //
    // Required on CREATE so that stops accumulating. Not required on EDIT:
    // blocking an edit of an existing listing until the provider finds GPS
    // would trap them, and editing without setting a location does not add
    // any new location-less rows.
    //
    // If neither a captured nor a profile-derived position is available, the
    // form does not block on a fresh GPS capture by default: forcing location
    // service on when the provider is not ready to share it is what made this
    // screen feel like it "required GPS" for every save. The provider may
    // still tap "Use GPS" above, and proximity search is only accurate when a
    // real point exists.
    if (!_isEdit && _lat == null && _lng == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
          'Save anyway? This listing will not be found by nearby search until '
          'a location is set. Tap "Use GPS" above to add one before saving.',
        ),
        backgroundColor: AppTheme.warning,
        duration: const Duration(seconds: 5),
      ));
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Save without a location?'),
          content: const Text(
            'You can still save this product. It will not appear in nearby '
            'search until you set a GPS location on it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Go back'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save anyway'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final price = double.tryParse(_priceCtrl.text) ?? 0;
      final qty = int.tryParse(_qtyCtrl.text);
      // Unit-priced listings carry the per-unit price in both `price` (so all
      // existing totals/fee math work) and `price_per_unit`, plus the unit.
      final unitValue = _unitMode ? _unit : null;
      final perUnitPrice = _unitMode ? price : 0.0;

      String productId;
      // Real listing GPS: geography point from the captured device position
      // (falls back to the business profile location).
      // Prefer a freshly captured point; fall back to the business profile
      // location so an edit can save without a new capture. Both of these are
      // nullable and neither forces a GPS capture: the screen above only asks
      // for location when the provider wants a precise point, and a listing is
      // not published until it is actually saved.
      final lat = _lat;
      final lng = _lng;
      final locationValue =
          (lat != null && lng != null) ? 'SRID=4326;POINT($lng $lat)' : null;

      if (_isEdit) {
        await client.from('products').update({
          'name': _nameCtrl.text.trim(),
          'description':
              _descCtrl.text.trim().isNotEmpty ? _descCtrl.text.trim() : null,
          'price': price,
          'price_per_unit': perUnitPrice,
          'unit': unitValue,
          'quantity': qty,
          'category_id': _categoryId,
          'is_available': _isAvailable,
          if (locationValue != null) 'location': locationValue,
        }).eq('id', widget.productId!);
        productId = widget.productId!;
      } else {
        final created = await client
            .rpc('create_provider_product', params: {
              'p_provider_id': _providerId,
              'p_name': _nameCtrl.text.trim(),
              'p_description': _descCtrl.text.trim().isNotEmpty
                  ? _descCtrl.text.trim()
                  : null,
              'p_price': price,
              'p_category_id': _categoryId,
              'p_quantity': qty,
              'p_price_per_unit': perUnitPrice,
              'p_unit': unitValue,
              'p_is_available': _isAvailable,
              'p_lat': lat,
              'p_lng': lng,
            })
            .single();
        productId = created['id'] as String;
      }

      // The availability gate is written separately, and best-effort.
      //
      // Deliberately NOT folded into the update above: the column is added by
      // migration 20260927000074, and between the app being installed and
      // that migration being applied the column does not exist. A single
      // combined update would then fail on an undefined column and the
      // provider could not save ANY edit to a listing -- a much worse failure
      // than not being able to set one new switch.
      //
      // Written for both create and edit, and including `false`, so turning
      // the gate off is exactly as reliable as turning it on. create and edit
      // share this because a newly created listing comes back with the
      // column's default of false and would otherwise need a second branch.
      var gateSaved = true;
      try {
        await client.from('products').update({
          'requires_availability_confirmation': _requiresAvailabilityConfirmation,
          'city': _city,
        }).eq('id', productId);
      } catch (_) {
        gateSaved = false;
      }

      // Upload new images.
      //
      // The path MUST start with the caller's own auth uid: the storage
      // policies match the object NAME inside the bucket, and every write
      // policy on this bucket scopes the object to auth.uid(). It previously
      // read 'product-images/$productId/...', which put the BUCKET name in
      // the first segment -- that only worked because migration 0033 had
      // widened the INSERT policy to `bucket_id = 'product-images'` with no
      // path check at all, which also let any signed-in account overwrite any
      // provider's listing photo. 20260927000048 restores the owner check, so
      // the two halves land together.
      final uid = client.auth.currentUser?.id;
      if (uid == null) {
        throw Exception('Not signed in — cannot upload listing images');
      }
      for (var i = 0; i < _newImages.length; i++) {
        final file = _newImages[i];
        final fileName =
            '${productId}_${DateTime.now().millisecondsSinceEpoch}_$i.jpg';
        final path = '$uid/$productId/$fileName';
        await client.storage
            .from('product-images')
            .upload(path, file, fileOptions: const FileOptions(upsert: true));
        await client.from('product_images').insert({
          'product_id': productId,
          'storage_path': path,
          'sort_order': i,
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            !gateSaved
                // The listing saved; only the optional settings did not.
                // Saying "Product updated" here would leave a provider
                // believing buyers must confirm availability — or that the
                // city they chose — was saved when it was not.
                ? 'Listing saved, but the optional settings (city, "Confirm '
                    'before payment") could not be saved. Try again in a '
                    'moment.'
                : (_isEdit ? 'Product updated' : 'Product created'),
          ),
          backgroundColor: gateSaved ? null : AppTheme.warning,
        ));
        context.pop();
      }
    } catch (e) {
      // Item I: if the server refused because this build is too old, raise the
      // update gate at once rather than leaving the provider retrying a save
      // that cannot succeed until the app is updated.
      AppUpdateService.instance.notePossibleRefusal(e);
      if (mounted) {
        // A refusal from the fulfilment gate is not a failed save, it is an
        // answer about what the provider must do first. Showing it as a
        // snackbar is what made this look like a broken button: the provider
        // typed the whole listing, pressed Save, and got a line of text with
        // no way to act on it and nothing on the form explaining why.
        if (ProviderReadiness.isPublishRefusal(e)) {
          await showPublishBlockedDialog(context, e.toString());
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(friendlyErrorWithRef(e,
                  context: 'Could not save this product',
                  source: 'product_save'))));
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Capture the real device GPS for this listing (search distance +
  /// buyer directions use it).
  Future<void> _useCurrentLocation() async {
    setState(() => _capturingGps = true);
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!mounted) return;
    if (r.success) {
      setState(() {
        _lat = r.position!.latitude;
        _lng = r.position!.longitude;
        _capturingGps = false;
      });
    } else {
      setState(() => _capturingGps = false);
    }
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? 'Edit Product' : 'Add Product')),
      body: _error != null
          ? LoadErrorView(message: _error!, onRetry: _load)
          : _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Form(
                key: _formKey,
                child: Column(
                  children: [
                    BirrTextField(
                      label: 'Product Name',
                      controller: _nameCtrl,
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    BirrTextField(
                      label: 'Description',
                      controller: _descCtrl,
                      maxLines: 3,
                    ),
                    const SizedBox(height: 16),
                    // Pricing mode: fixed price OR price per unit (kg/liter).
                    Row(
                      children: [
                        Expanded(
                          child: ChoiceChip(
                            label: const Text('Fixed price'),
                            selected: !_unitMode,
                            onSelected: (_) =>
                                setState(() => _unitMode = false),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ChoiceChip(
                            label: const Text('Price per unit'),
                            selected: _unitMode,
                            onSelected: (_) => setState(() => _unitMode = true),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_unitMode)
                      Row(
                        children: [
                          Expanded(
                            child: ChoiceChip(
                              label: const Text('per kilogram'),
                              selected: _unit == 'KG',
                              onSelected: (_) => setState(() => _unit = 'KG'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ChoiceChip(
                              label: const Text('per liter'),
                              selected: _unit == 'LTR',
                              onSelected: (_) => setState(() => _unit = 'LTR'),
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 8),
                    BirrTextField(
                      label: _unitMode
                          ? 'Price per ${_unit == 'KG' ? 'kg' : 'liter'} (ETB)'
                          : 'Price (ETB)',
                      controller: _priceCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    if (!_unitMode)
                      BirrTextField(
                        label: 'Quantity (optional)',
                        controller: _qtyCtrl,
                        keyboardType: TextInputType.number,
                      ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: _categoryId,
                      decoration: const InputDecoration(labelText: 'Category'),
                      items: _categories
                          .map((c) => DropdownMenuItem(
                              value: c['id'] as String,
                              child: Text(c['name'] ?? '')))
                          .toList(),
                      onChanged: (v) {
                        setState(() => _categoryId = v);
                        // Item H: re-quote through the same resolver when the
                        // category changes — a stale fee on screen is exactly
                        // the drift this preview exists to remove.
                        final pid = _providerId;
                        if (pid != null) {
                          _loadFeePreview(pid);
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    // City: which market this listing belongs to. "All
                    // cities" (empty) is offered first and stays the default
                    // for a new listing, because a null city is what the
                    // feed already treats as "visible everywhere".
                    DropdownButtonFormField<String>(
                      initialValue: _city,
                      decoration: const InputDecoration(
                        labelText: 'City',
                        helperText:
                            'Where this listing is based — or all cities',
                      ),
                      items: [
                        const DropdownMenuItem<String>(
                            value: null, child: Text('All cities')),
                        ...CityService.knownCities.map((c) =>
                            DropdownMenuItem<String>(
                                value: c, child: Text(c))),
                      ],
                      onChanged: (v) => setState(() => _city = v),
                    ),
                    const SizedBox(height: 16),
                    // Listing GPS capture row
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.creamDark,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.place_outlined,
                              size: 20, color: AppTheme.primaryGreen),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _lat != null && _lng != null
                                  ? '${_lat!.toStringAsFixed(5)}, ${_lng!.toStringAsFixed(5)}'
                                  : 'No GPS location set — required to publish',
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          TextButton.icon(
                            onPressed:
                                _capturingGps ? null : _useCurrentLocation,
                            icon: _capturingGps
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppTheme.primaryGreen))
                                : const Icon(Icons.my_location, size: 16),
                            label: const Text('Use GPS'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile(
                      title: const Text('Available'),
                      value: _isAvailable,
                      onChanged: (v) => setState(() => _isAvailable = v),
                      activeColor: AppTheme.primaryGreen,
                      contentPadding: EdgeInsets.zero,
                    ),
                    SwitchListTile(
                      title: const Text('Confirm before payment'),
                      subtitle: const Text(
                        'For bookings that are only true for a specific date, '
                        'room or slot. The buyer requests the order first; you '
                        'confirm it is available, and only then do they see '
                        'your payment details. Leave off for things you can '
                        'sell straight from stock.',
                      ),
                      value: _requiresAvailabilityConfirmation,
                      onChanged: (v) =>
                          setState(() => _requiresAvailabilityConfirmation = v),
                      activeColor: AppTheme.primaryGreen,
                      contentPadding: EdgeInsets.zero,
                    ),
                    const SizedBox(height: 16),
                    // Images section
                    Row(
                      children: [
                        const Text('Images',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: _pickImages,
                          icon: const Icon(Icons.add_photo_alternate_outlined,
                              size: 18),
                          label: const Text('Add'),
                        ),
                      ],
                    ),
                    if (_existingImages.isNotEmpty || _newImages.isNotEmpty)
                      PhotoGrid(
                        items: [
                          for (final img in _existingImages)
                            PhotoGridItem.stored(
                              img['storage_path'] as String? ?? '',
                              bucket: 'product-images',
                            ),
                          for (final file in _newImages)
                            PhotoGridItem.file(file),
                        ],
                      ),
                    const SizedBox(height: 24),
                    if (!_registrationFeePaid) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: AppTheme.gold.withOpacity(0.10),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: AppTheme.gold.withOpacity(0.45)),
                        ),
                        child: Text(_activationMessage,
                            style: const TextStyle(
                                fontSize: 13, color: AppTheme.textSecondary)),
                      ),
                    ],
                    if (_listingFeeQuote != null || _commissionQuote != null)
                      _InlineFeePreview(
                        listing: _listingFeeQuote,
                        commission: _commissionQuote,
                      ),
                    SizedBox(
                      width: double.infinity,
                      child: PrimaryButton(
                        label: _isEdit ? 'UPDATE PRODUCT' : 'CREATE PRODUCT',
                        isLoading: _saving,
                        onPressed: _save,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// Item H: the inline fee preview for a listing — the product listing fee and
/// the commission percent, each labelled with the reader that answered it.
/// A reader that could not be reached renders as "unavailable" instead of a
/// confident zero, because the server re-resolves on save and a fabricated 0
/// would read as "free".
class _InlineFeePreview extends StatelessWidget {
  const _InlineFeePreview({this.listing, this.commission});

  final FeeQuote? listing;
  final FeeQuote? commission;

  String _feeText(FeeQuote? q) {
    if (q == null || !q.hasValue) return 'unavailable';
    final v = q.value!;
    return v == v.roundToDouble()
        ? 'ETB ${v.toStringAsFixed(0)}'
        : 'ETB ${v.toStringAsFixed(2)}';
  }

  String _pctText(FeeQuote? q) {
    if (q == null || !q.hasValue) return 'unavailable';
    final v = q.value!;
    return v == v.roundToDouble()
        ? '${v.toStringAsFixed(0)}%'
        : '${v.toStringAsFixed(2)}%';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 16),
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
                'Fees on this listing',
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
            'Listing fee: ${_feeText(listing)}',
            style: const TextStyle(
                fontSize: 12.5, height: 1.4, color: AppTheme.textSecondary),
          ),
          Text(
            'Commission per sale: ${_pctText(commission)}',
            style: const TextStyle(
                fontSize: 12.5, height: 1.4, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 4),
          const Text(
            'Resolved by the same readers the charge uses.',
            style: TextStyle(
                fontSize: 11.5, height: 1.35, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }
}
