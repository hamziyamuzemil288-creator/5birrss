import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/legal_document.dart';

/// The two prohibited-content clauses, defined ONCE.
///
/// WHY THEY LIVE HERE, IN A CONST
/// ------------------------------
/// The same two rules have to appear in two documents: the standalone Terms of
/// Service below, and the combined Terms & Privacy Policy that the registration
/// checkbox accepts (`kTermsAndPrivacyText`). Written twice they drift, and the
/// one that drifts is the one a buyer agreed to — so the wording is
/// interpolated into both from this single constant. Change it here and both
/// documents, the in-app pages and the public mirror move together.
///
/// The wording is deliberately legal rather than conversational: a rule that
/// says "no phone numbers in photos or we delete your account" is not the
/// clause a policy reviewer, an appeal or a lawyer can act on.
const String kProhibitedContentClauses = '''## 5. Prohibited content and conduct

- **Contact details inside listing content.** Publishing a telephone number,
  or any other direct contact detail, within a product image or a product
  description is prohibited. A listing is a commercial offer, not a contact
  channel: directly published contact details exist to move a trade off the
  platform, and a trade conducted off the platform cannot be verified, priced
  or protected. A breach of this clause results in **permanent deletion of the
  account** and the removal of every listing it published.
- **Circumvention, fraud and dishonest conduct.** Attempting to cheat,
  defraud, or otherwise circumvent the platform is prohibited. This includes
  arranging payment outside the platform in order to avoid its fees,
  falsifying or reusing a payment proof, misrepresenting a transaction, or
  inducing another user to do any of the same. Conduct under this clause may
  result in permanent deletion of the account, the withholding of funds
  obtained through it pending investigation, and the initiation of **legal
  action or legal procedure** against the persons responsible.
''';

/// The standalone Terms of Service.
///
/// This is the operative agreement, kept separate from the data-handling
/// document it used to be welded to. It is reached from the About screen and
/// from the profile menu, and mirrored — section for section — at
/// `docs/terms-of-service.html`, which is the URL Play Console can open.
///
/// The combined Terms & Privacy Policy is NOT removed by having this page: the
/// registration checkbox still accepts one document, and that document still
/// carries these clauses (interpolated from [kProhibitedContentClauses]).
const String kTermsOfServiceText = '''
# Aliob — Terms of Service
**Version 2026-10-15**

These Terms of Service ("Terms") govern your use of the Aliob application and
the marketplace it operates. By creating an account, or by continuing to use an
account you already hold, you accept these Terms. If you do not accept them,
you must not use the platform.

## 1. Agreement and eligibility
Aliob is operated as a single marketplace connecting shops, service providers
and vehicles with customers. You must be at least 18 years old, and legally
able to enter into a binding agreement, to hold an account. You are responsible
for the accuracy of every detail you give us and for activity on your account.

## 2. Accounts and accurate information
- Keep your registration details, and any document you upload for
  verification, true, current and your own.
- Do not create an account for another person, hold more than one account to
  evade a suspension, or transfer your account to anyone else.
- You are responsible for keeping your password confidential.

## 3. Fair dealing after contact is revealed
Once a payment has been verified and contact details are released, both parties
must treat each other with respect. You must not:

- Spam, harass, threaten, or abuse the other party by phone, message, or in
  person.
- Pressure the other party to cancel an order outside the app.
- Share the other party's contact details or location with anyone else.

## 4. Payments are made through the platform
All payments for goods, services, bookings and deliveries arranged on Aliob are
made through the platform, into the payment account Aliob publishes inside the
app, and are evidenced by a payment proof uploaded on the order. You must not:

- Pay, or ask to be paid, directly outside the platform in order to avoid the
  platform's fees.
- Deliver goods or services settled outside the platform and then claim the
  platform's protection for that transaction.

Payments made outside the platform are not protected. The platform cannot
recover money paid outside it, and cannot act against an account for a
transaction it was never shown.

''' + kProhibitedContentClauses + '''
## 6. Listings and representations
- Describe products, services, vehicles and prices accurately.
- Upload photographs of what you actually offer, and hold any licence your
  service legally requires.
- Keep availability, stock and prices current.
- Do not create fake listings, fake reviews, or fake accounts.

## 7. Consequences of a breach
Breaches of these Terms are answered in rising order of severity:

1. A warning and a request to correct the issue.
2. Removal of the offending listing or content.
3. Temporary suspension of the account.
4. Permanent deletion of the account, with any pending wallet balance withheld
   pending investigation.
5. Legal action or legal procedure, where the breach is fraud, circumvention,
   a threat, or otherwise unlawful.

A breach of clause 5 is answered at step 4 or 5 directly: publishing contact
details inside listing content results in permanent account deletion, and
circumvention or fraud may additionally be pursued as described in that clause.

## 8. Suspension and termination
We may suspend or close an account to protect users, to comply with the law, or
to answer a breach of these Terms. You may close your account at any time from
your profile; see the account-deletion page for exactly what is deleted and
what is kept for legal, accounting and dispute purposes.

## 9. Changes to these Terms
If these Terms change materially, the new version is published with a new
version number and you will be asked to review and accept it before continuing
to use the features it covers.

## 10. Contact
Questions about these Terms: WhatsApp **0917686990** or email
**muktarbiya329@gmail.com**.
''';

/// Full-screen Terms of Service page, opened from the About screen and the
/// profile menu.
class TermsOfServiceScreen extends StatelessWidget {
  const TermsOfServiceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terms of Service'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: const LegalDocument(text: kTermsOfServiceText),
    );
  }
}
