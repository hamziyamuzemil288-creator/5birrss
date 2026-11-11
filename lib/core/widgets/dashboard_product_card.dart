import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/product.dart';
import '../theme/app_theme.dart';
import 'product_engagement.dart' show ProviderNameTag;

/// One listing in the dashboard's three-up grid.
///
/// The shared ProductCard carries ratings, rank, likes and a BUY button, which
/// is the right card for a two-up discovery surface and too much for a tile
/// that is only ~100dp wide. This is the same data in the compact form the
/// brief asks for: image, name, price, provider and city, with the whole tile
/// opening the existing product detail. It reuses the model's cover-photo rule
/// and the batched ProviderNameService, so it costs no extra query per tile.
class DashboardProductCard extends StatelessWidget {
  final Product product;
  final VoidCallback? onTap;

  const DashboardProductCard({
    super.key,
    required this.product,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final path = product.coverStoragePath;
    final imageUrl = path == null
        ? null
        : Supabase.instance.client.storage
            .from('product-images')
            .getPublicUrl(path);
    final city = (product.city ?? '').trim();

    return Semantics(
      button: true,
      label: '${product.name}, ${product.formattedDisplayPrice}',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.cardBorder, width: 0.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.035),
                blurRadius: 7,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(12)),
                  child: ColoredBox(
                    color: AppTheme.creamDark,
                    child: SizedBox.expand(
                      child: imageUrl == null
                          ? const _ImageFallback()
                          : CachedNetworkImage(
                              imageUrl: imageUrl,
                              fit: BoxFit.contain,
                              alignment: Alignment.center,
                              filterQuality: FilterQuality.low,
                              placeholder: (_, __) => const Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: AppTheme.primaryGreen),
                                ),
                              ),
                              errorWidget: (_, __, ___) =>
                                  const _ImageFallback(),
                            ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 1),
                    ProviderNameTag(providerId: product.providerId),
                    if (city.isNotEmpty)
                      Text(
                        city,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    const SizedBox(height: 3),
                    Text(
                      product.formattedDisplayPrice,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.primaryGreen,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImageFallback extends StatelessWidget {
  const _ImageFallback();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Icon(Icons.image_outlined, color: AppTheme.textMuted, size: 26),
    );
  }
}
