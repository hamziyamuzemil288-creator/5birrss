import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/document_upload_service.dart';
import '../../core/services/provider_doc_gate.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/document_upload_card.dart';
import '../../core/widgets/load_error_view.dart';

/// Settings → Verify Documents (Part 1 of the registration rework).
///
/// Document verification is VOLUNTARY: a provider can post products and use
/// the app from the moment a self-service signup completes — the server rule
/// that used to refuse unverified documents was retired for service
/// providers by migration 20261014000001. This screen is where a provider
/// who WANTS to verify uploads the document, sees what is on file and sees
/// what state each submission is in. It is also the onboarding step a
/// staff-assisted signup is walked into right after registration, because a
/// staff-assisted provider's account only becomes active for trading once an
/// administrator reviews these documents (migration 20261014000000 keeps that
/// path at PENDING_APPROVAL on purpose).
///
/// Deliberately plain: the upload path, the storage bucket and the review
/// queue are the same ones the pre-existing verification gate uses
/// (DocumentUploadService → user_documents → the admin's Document
/// Verification screen), so nothing here invents a second review pipeline.
class ProviderDocumentsScreen extends StatefulWidget {
  const ProviderDocumentsScreen({super.key});

  @override
  State<ProviderDocumentsScreen> createState() =>
      _ProviderDocumentsScreenState();
}

class _ProviderDocumentsScreenState extends State<ProviderDocumentsScreen> {
  final _picker = ImagePicker();

  List<Map<String, dynamic>> _documents = const [];
  bool _loading = true;
  String? _error;

  String? _docType;
  String? _otherLabelControllerHack; // reserved; OTHER label prompt below
  File? _picked;
  bool _uploading = false;
  String? _uploadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      setState(() {
        _loading = false;
        _error = 'Sign in again to manage your documents.';
      });
      return;
    }
    try {
      final rows = await Supabase.instance.client
          .from('user_documents')
          .select('id, document_type, other_document_label, verification_status, created_at')
          .eq('user_id', userId)
          .order('created_at', ascending: false);
      if (!mounted) return;
      setState(() {
        _documents = List<Map<String, dynamic>>.from(rows as List);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load your documents');
      });
    }
  }

  Future<void> _pick() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Add a document photo',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined,
                  color: AppTheme.primaryGreen),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined,
                  color: AppTheme.primaryGreen),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final file = await _picker.pickImage(source: source, imageQuality: 80);
    if (file == null) return;
    setState(() => _picked = File(file.path));
  }

  Future<void> _upload() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    final type = _docType;
    if (userId == null || type == null || _picked == null) {
      setState(() =>
          _uploadError = 'Choose the document type and a photo first.');
      return;
    }
    String? otherLabel;
    if (type == ProviderDocGate.otherDocType) {
      final typed = await showDialog<String>(
        context: context,
        builder: (ctx) {
          final ctrl = TextEditingController(text: _otherLabelControllerHack);
          return AlertDialog(
            title: const Text('What is this document?'),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Document name',
                hintText: 'e.g. Residence letter',
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              TextButton(
                  onPressed: () =>
                      Navigator.pop(ctx, ctrl.text.trim()),
                  child: const Text('Use this')),
            ],
          );
        },
      );
      if (typed == null || typed.isEmpty) return;
      otherLabel = typed;
      _otherLabelControllerHack = typed;
    }

    setState(() {
      _uploading = true;
      _uploadError = null;
    });
    try {
      await DocumentUploadService.instance.uploadAndRecord(
        file: _picked!,
        userId: userId,
        documentType: type,
        otherDocumentLabel: otherLabel,
      );
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _picked = null;
        _docType = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Document submitted — our team will review it.')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _uploadError = friendlyError(e, context: 'Could not upload the document');
      });
    }
  }

  static String _statusLabel(String? raw) {
    switch ((raw ?? 'MANUAL_REVIEW').toUpperCase()) {
      case 'VERIFIED':
      case 'AUTO_APPROVED':
        return 'Approved';
      case 'SUSPECTED_FRAUD':
        return 'Flagged — contact support';
      case 'REJECTED':
        return 'Rejected — upload a clearer photo';
      default:
        return 'Waiting for review';
    }
  }

  static Color _statusColor(String? raw) {
    switch ((raw ?? 'MANUAL_REVIEW').toUpperCase()) {
      case 'VERIFIED':
      case 'AUTO_APPROVED':
        return AppTheme.success;
      case 'SUSPECTED_FRAUD':
      case 'REJECTED':
        return AppTheme.error;
      default:
        return AppTheme.warning;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verify Documents')),
      body: _error != null
          ? LoadErrorView(message: _error!, onRetry: _load)
          : _loading
              ? const Center(
                  child:
                      CircularProgressIndicator(color: AppTheme.primaryGreen))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryGreen.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: AppTheme.primaryGreen.withOpacity(0.3)),
                        ),
                        child: const Text(
                          'Verifying your identity is optional and takes a '
                          'minute. Your products are visible either way — '
                          'verified accounts earn extra trust with buyers, and '
                          'our team reviews submissions during working hours.',
                          style: TextStyle(fontSize: 13, height: 1.45),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_documents.isNotEmpty) ...[
                        const Text('On file',
                            style: AppTheme.sectionHeader),
                        const SizedBox(height: 8),
                        for (final d in _documents)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: AppTheme.surface,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: AppTheme.cardBorder),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    (d['document_type'] as String?) ?? 'Document',
                                    style: const TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                                Text(
                                  _statusLabel(
                                      d['verification_status'] as String?),
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: _statusColor(
                                          d['verification_status']
                                              as String?)),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 16),
                      ],
                      const Text('Add a document',
                          style: AppTheme.sectionHeader),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        value: _docType,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Document type *',
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                        items: [
                          ...ProviderDocGate.acceptedDocTypes.entries
                              .map((e) => DropdownMenuItem(
                                    value: e.key,
                                    child: Text(e.value),
                                  )),
                          const DropdownMenuItem(
                            value: ProviderDocGate.otherDocType,
                            child: Text('Other document'),
                          ),
                        ],
                        onChanged: (v) => setState(() => _docType = v),
                      ),
                      const SizedBox(height: 12),
                      DocumentUploadCard(
                        title: 'Document photo',
                        subtitle: 'Clear photo of the whole document',
                        file: _picked,
                        isUploading: _uploading,
                        error: _uploadError,
                        onPick: _pick,
                        onRemove: _picked == null
                            ? null
                            : () => setState(() => _picked = null),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed:
                              _uploading || _picked == null || _docType == null
                                  ? null
                                  : _upload,
                          child: _uploading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Text('SUBMIT FOR REVIEW'),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }
}
