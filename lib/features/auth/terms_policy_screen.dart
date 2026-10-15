import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/legal_document.dart';
import 'terms_of_service_screen.dart' show kProhibitedContentClauses;

/// Version of the Terms & Privacy Policy currently in force. Bump this
/// whenever the policy text changes so existing users can be re-prompted.
///
/// Bumped on 2026-10-15 for the two prohibited-content clauses (5.1 and 5.2),
/// which is the change that makes the new version a materially different
/// document from the one a user accepted at 2026-09-20.
const String kTermsVersion = '2026-10-15';

/// Full Terms & Privacy Policy text, shown as a dedicated page and linked
/// from the registration checkbox. Kept in one place so the registration
/// forms and this page can never drift apart.
///
/// The prohibited-content clauses are interpolated from
/// [kProhibitedContentClauses] rather than retyped, so the document a user
/// accepts here and the standalone Terms of Service (`/terms-of-service`) can
/// never disagree about the two rules the founder added: no contact details
/// inside listing content, and no circumvention or fraud.
const String kTermsAndPrivacyText = '''
# Aliob — Terms & Privacy Policy
**Version 2026-10-15**

Welcome to Aliob, Ethiopia's local marketplace for goods, services, and
rides. By creating an account you agree to the rules below. They exist to
keep every trade safe, honest, and fair for both sides.

## 1. Fair dealing after contact is revealed
Once a payment has been verified and contact details are revealed, both
parties must treat each other with respect. You must not:

- Spam, harass, threaten, or abuse the other party by phone, message, or in person.
- Pressure the other party to cancel an order outside the app.
- Share the other party's contact details or location with anyone else.

## 2. Keep payments inside the app
All payments must be made through Aliob's payment flow, into the payment
account the platform publishes in the app, and evidenced by the payment proof
you upload on the order. You must not:

- Ask another party to pay you directly (cash, Telebirr transfer, or any other off-platform method) to bypass the app's payment process.
- Deliver goods or services paid for outside the app and then claim support or protection from Aliob.

Off-platform deals have no protection. If you are scammed outside the app,
Aliob cannot recover your money or act against the other account.

## 3. Represent yourself and your listings honestly

- Describe products, services, vehicles, and prices accurately.
- Upload real photos of what you actually offer.
- Keep prices, availability, and stock up to date.
- Do not create fake listings, fake reviews, or fake accounts.
- Providers must hold any licence their service legally requires.

## 4. Consequences of violations
Breaking these rules can lead to, in rising order of severity:

1. A warning and a request to correct the issue.
2. Removal of the offending listing or content.
3. Temporary suspension of your account.
4. Permanent suspension, with any pending wallet balance withheld pending investigation of the violation.

Serious matters (fraud, threats, or illegal activity) may also be reported
to the authorities.

''' + kProhibitedContentClauses + '''
## 6. How Aliob uses your data
Aliob collects and uses the minimum data needed to run a safe marketplace:

- **Phone number** — to contact you about your orders and account, and so support can reach you when you report an issue.
- **National ID / licence photos** — to verify your identity before your account is approved. Only our admin team can view them.
- **Location data** — collected only to enable ride matching, delivery location sharing between buyer and seller after payment verification, and directions. Location is never sold or used for advertising.
- **Payment screenshots and transaction records** — to verify payments and resolve disputes.

Your documents and contact details are never shared with other users,
except the specific details released after a payment has been verified
(seller contact and delivery location for an order you paid for).

## 7. Your choices
You can request account deletion at any time from your profile. Deleting
your account removes your personal details; transaction records needed for
legal and dispute purposes are retained as required.

## 8. Changes to these terms
If this policy changes materially, you'll be asked to review and accept
the new version before continuing to use updated features.

Questions? Contact support on WhatsApp at **0917686990** or by email at
**muktarbiya329@gmail.com**.
''';

/// Full-screen Terms & Privacy Policy page, opened from the registration
/// checkbox ("I agree to the Terms & Privacy Policy").
///
/// The rendering itself lives in [LegalDocument] — the same widget the
/// standalone Terms of Service page uses, so the two legal pages cannot drift
/// into two designs.
class TermsPolicyScreen extends StatelessWidget {
  final bool returnToSignup;

  const TermsPolicyScreen({super.key, this.returnToSignup = false});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terms & Privacy Policy'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              returnToSignup ? context.pop() : context.go('/role-select'),
        ),
      ),
      body: const LegalDocument(text: kTermsAndPrivacyText),
    );
  }
}
