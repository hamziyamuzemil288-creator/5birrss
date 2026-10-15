import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Stands in for the payment section when the basket needs a provider
/// confirmation first.
///
/// Shared by the two screens that meet this case, because they meet it in the
/// same words on purpose:
///
///   * checkout — says what CONTINUE TO PAYMENT will do, before it is pressed;
///   * the payment screen — says why the accounts and the upload are not there,
///     so an order that will be paid later does not read as a broken screen.
///
/// The copy is the wording this app already showed at checkout, moved rather
/// than rewritten. It promises nothing about timing because the provider sets
/// it, and it names where the request can be watched — Orders shows it with
/// live status, which is the row's state and not this screen's.
class AvailabilityNotice extends StatelessWidget {
  const AvailabilityNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.gold.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.gold.withOpacity(0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.hourglass_top_rounded,
                  size: 18, color: AppTheme.gold),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Waiting for provider to confirm availability',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'This booking is made for a specific date, room or slot, so the '
            'provider has to confirm it is available before you pay. Send the '
            'request now — as soon as they confirm, the payment details and '
            'your upload option appear on the order, and you will be notified.',
            style: TextStyle(fontSize: 12.5, height: 1.45),
          ),
        ],
      ),
    );
  }
}
