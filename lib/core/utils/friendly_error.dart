/// Turns an exception into a sentence a real person can act on.
///
/// The app used to interpolate the raw exception straight into snackbars
/// (`Text('Error: $e')`) and into full-screen error bodies. On a phone that
/// surfaces things like `PostgrestException(code: PGRST301)` or
/// `HttpException: Connection closed before full header was received`, which
/// tells the user nothing about what to do next and leaks schema detail to
/// anyone who screenshots it.
///
/// Deliberately dependency-free (dart:core only) so it can be imported from
/// any screen without risking an import cycle. The raw error is still sent to
/// the console for debugging — it is only the user-visible text that changes.
library;

/// Default text when nothing more specific is recognised. Never empty, never
/// technical, and always paired with a retry affordance by the caller.
const String _fallback = 'Something went wrong. Please try again.';

/// Turn the server's `CODE: REASON,REASON` payload into phrases a provider
/// can act on.
///
/// Deliberately tolerant: an unrecognised reason contributes nothing rather
/// than leaking `SOME_NEW_CODE` onto the screen, and a payload with no
/// reasons at all yields an empty list, which the caller turns into a
/// generic-but-useful "open your business profile".
///
/// Kept dependency-free (dart:core only) so friendly_error.dart stays
/// importable from any screen without risking a cycle.
List<String> _fulfilmentReasons(String raw) {
  const phrases = {
    'DOCUMENTS_UNVERIFIED':
        'your identity document is still being reviewed',
    'ACTIVATION_FEE_UNPAID': 'the one-time activation fee is unpaid',
    'WALLET_EMPTY':
        'your wallet is empty, so the platform fee cannot be covered',
    'WALLET_BELOW_MINIMUM':
        'your wallet is below the minimum balance the platform requires '
        'before posting',
    'SUBSCRIPTION_UNPAID':
        'your subscription is unpaid, so your account is suspended',
    'ACCOUNT_NOT_APPROVED': 'your account has not been approved yet',
    'PROVIDER_NOT_FOUND': 'that business no longer exists',
  };
  // Anchored on the code itself rather than on its position. PostgREST wraps
  // the detail in a JSON envelope whose shape differs between the exception's
  // toString() and a raw response body, so "everything after the first colon"
  // matched in one case and not the other. This matches in both.
  //
  // Two codes are accepted: the reason-carrying one, and the bare code the
  // create paths used to raise (migration 0117 changed the server, not the
  // clients that are already installed). A bare code yields no reasons, which
  // is the correct outcome -- the caller then shows the generic sentence
  // rather than inventing reasons the server did not give.
  final match = RegExp(
    'provider_not_fulfilment_ready\\s*:\\s*([A-Za-z_,\\s]*)',
    caseSensitive: false,
  ).firstMatch(raw);
  if (match == null) return const [];
  final out = <String>[];
  for (final part in (match.group(1) ?? '').split(RegExp(r'[,\s]+'))) {
    // Postgres upper-cases RAISE EXCEPTION text, but the reason list is
    // whatever the transport preserved, so the key is normalised here rather
    // than assuming.
    final phrase = phrases[part.trim().toUpperCase()];
    if (phrase != null && !out.contains(phrase)) out.add(phrase);
  }
  return out;
}

/// Map an arbitrary thrown object to calm, actionable user-facing text.
///
/// [context] is an optional short prefix such as 'Could not load your
/// orders' so the sentence still reads naturally in context:
///
/// ```dart
/// SnackBar(content: Text(friendlyError(e, context: 'Could not load your orders')))
/// ```
///
/// Known failure modes are matched in priority order — network problems are
/// the most common and the most actionable, so they win.
String friendlyError(Object error, {String? context}) {
  final raw = error.toString();
  final lower = raw.toLowerCase();
  final prefix = (context == null || context.trim().isEmpty) ? '' : '$context. ';

  String message;

  // ── The forced-update gate (item I) ──
  //
  // A write from a build below the platform's minimum is refused with
  // APP_UPDATE_REQUIRED. This is checked FIRST because it is not a retryable
  // error: it is an instruction. Reading it as "no internet, try again" would
  // have the user retrying a call that will keep failing until they update.
  if (_any(lower, ['app_update_required'])) {
    message = 'This version of Aliob is no longer supported. Update the app '
        'to continue — your data and sign-in are kept.';
  }
  // ── Transport-level failures: the user's own situation, not the app's ──
  else if (_any(lower, [
    'socketexception',
    'failed host lookup',
    'connection refused',
    'connection reset',
    'connection closed',
    'connection closed before full header',
    'network is unreachable',
    'no address associated',
    'nodename nor servname',
    'timedout',
    'timeout exception',
    'timeout',
  ])) {
    message = 'No internet connection. Check your network and try again.';
  } else if (_any(lower, [
    'handshakeexception',
    'certificate',
    'ssl',
  ])) {
    message = 'Could not establish a secure connection. Please try again.';
  }
  // ── Auth / session ──
  //
  // 'invalid login credentials' and 'email not confirmed' used to sit in this
  // list, which made every one of them render as "Your session has expired."
  // That is actively wrong for a sign-in attempt: a person who has never had
  // a session cannot have an expired one, and a wrong password is not an
  // expiry. Both now say what they are, and the account-shaped failures are
  // checked FIRST because they are the ones with a distinct next action.
  else if (_any(lower, [
    'email not confirmed',
    'user is disabled',
    'user_banned',
    'email_exists',
    'signup is not allowed',
  ])) {
    message = 'That account cannot sign in with a password. Please contact '
        'support.';
  } else if (_any(lower, [
    'invalid login credentials',
  ])) {
    message = 'Invalid email or password.';
  } else if (_any(lower, [
    'jwt',
    'invalid token',
    'token is expired',
    'expired_token',
    'refresh token not found',
    'user not found',
    'new_password',
    'same as the old password',
  ])) {
    message = 'Your session has expired. Please sign in again.';
  } else if (_any(lower, [
    '401',
    'unauthorized',
    // The app's own "no session" refusal, raised by the SECURITY DEFINER
    // functions that must refuse an anonymous caller. Also a 400 from
    // PostgREST, not a 401, so without this it fell through to the generic
    // fallback and told a signed-out user to "try again" — which is exactly
    // what had already failed.
    'auth_required',
  ])) {
    message = 'Please sign in again to continue.';
  }
  // ── The provider fulfilment gate ──
  //
  // Migration 0113 answers a refusal with the REASONS rather than a bare
  // code: `PROVIDER_NOT_FULFILMENT_READY: DOCUMENTS_UNVERIFIED,WALLET_EMPTY`.
  //
  // This branch exists because "You do not have permission to do that" is the
  // single least useful sentence this product could show a provider who has
  // done everything right and is waiting on a review. Each reason is
  // translated into the thing they can actually DO about it, which is the
  // entire point of returning a list instead of a boolean.
  else if (_any(lower, [
    'provider_not_fulfilment_ready',
    // The BARE code the two create paths used to raise. Migration 0117 makes
    // them answer with the reason list instead, but an app that is already
    // installed can call a server this migration has not reached yet, and a
    // build in the Play Store keeps talking to the old body for as long as it
    // takes users to update. Mapping both means neither generation shows a
    // provider a machine token.
    'provider_not_activated_or_documents_required',
  ])) {
    final reasons = _fulfilmentReasons(raw);
    message = reasons.isEmpty
        ? 'Finish your account setup before you can publish. Open your '
            'business profile to see what is outstanding.'
        : 'Before you can publish: ${reasons.join('; ')}. Open your business '
            'profile to fix it.';
  }

  // The posting-fee backstop (migration 20261006000003): raised BEFORE the
  // insert when the wallet cannot cover the optional posting fee — a balance
  // that moved between the gate's read and the charge. Bare code, not a
  // reason list, so it gets its own branch. The sentence says the two things
  // a provider needs to know: nothing was taken, and the listing was not
  // created (so retrying after a recharge is safe and cannot duplicate).
  else if (_any(lower, ['posting_fee_insufficient'])) {
    message = 'The listing fee could not be covered by your wallet. '
        'Recharge and try again — nothing was charged and no listing was '
        'created.';
  }

  // No wallet row for the provider. This is a provisioning problem, not a
  // balance problem — recharging cannot help until the wallet exists — so
  // the sentence points at support rather than at the recharge screen.
  // Raised by create_provider_product's posting-fee path when an otherwise
  // ready provider somehow has no wallets row (migration 20261006000003).
  else if (_any(lower, ['wallet_not_found'])) {
    message = 'This business has no wallet on file yet. Please contact '
        'support so it can be created — recharging will not help until it '
        'exists.';
  }

  // ── Admin image takedown (Content Control) ──
  //
  // The moderation RPC refuses for reasons an administrator can ACT on —
  // and must never show them "Something went wrong": the whole point of the
  // clear-reason wrapper (0141) is that the server's own sentence reaches
  // the screen. `IMAGE_MODERATION_FAILED: <cause>` carries the underlying
  // error after the colon, so it is passed through verbatim (trimmed to a
  // readable length); the two stable refusals get fixed sentences.
  else if (_any(lower, ['image_moderation_failed'])) {
    final reason = RegExp(
            r'image_moderation_failed:\s*(.+)',
            caseSensitive: false)
        .firstMatch(raw)
        ?.group(1)
        ?.trim();
    final cleaned = reason == null || reason.isEmpty
        ? null
        : (reason.length > 160 ? '${reason.substring(0, 160)}…' : reason);
    message = cleaned == null
        ? 'The image could not be removed. Please try again.'
        : 'The image could not be removed: $cleaned';
  } else if (_any(lower, ['no_row_references_that_image'])) {
    message = 'That image is already gone — no row references it any more. '
        'Refresh the list to see the current state.';
  } else if (_any(lower, ['that_bucket_is_not_moderable'])) {
    message = 'That storage bucket cannot be moderated from this screen.';
  }

  // ── Authorisation (RLS denials arrive as plain 403s) ──
  //
  // `not_your_provider` is raised by the two create paths when the provider id
  // does not belong to the signed-in account. It is deliberately NOT folded
  // into the `auth_required` branch above: that one says "sign in again", and
  // the provider here is perfectly well signed in -- telling them to sign in
  // again would send them round a loop that cannot fix anything. It usually
  // means a stale screen from a previous account.
  else if (_any(lower, ['not_your_provider'])) {
    message = 'That business is not linked to this account. Go back to your '
        'dashboard and open it from there.';
  }
  //
  // `insufficient_permission` is the app's OWN refusal code, raised by
  // `RAISE EXCEPTION 'INSUFFICIENT_PERMISSION'` in the admin and staff RPCs.
  // PostgREST returns that as a 400, not a 403, and the message body is the
  // raw code — so without this entry a staff member who acted outside their
  // scope got the generic "Something went wrong" fallback, which tells them
  // nothing and reads like a bug. Migrations 110-112 put this code on the
  // five provider lifecycle actions, the task feed and payment verification,
  // so it stopped being rare.
  else if (_any(lower, [
    '403',
    'forbidden',
    'permission denied',
    'not authorized',
    'row-level security',
    'row level security',
    'pgrst301',
    'insufficient_permission',
    'admin_only',
  ])) {
    message = _any(lower, ['insufficient_permission'])
        // The overwhelmingly common cause is a staff member reaching past
        // their assigned city, so say that specifically rather than making
        // them guess. A CEO or super admin has no city scope and will never
        // see this branch reached against them.
        ? 'That is outside the area you are assigned to. Ask a manager or '
            'the CEO if you need access to it.'
        : 'You do not have permission to do that.';
  }
  // ── PostgREST could not resolve the call the app made ──
  //
  // PGRST202 and PGRST203 are NOT missing records, and this branch exists
  // because they were lumped in with 404 for the whole life of the app.
  //
  // PGRST202 means PostgREST cannot find a function matching the argument
  // names it was given, or cannot see one the caller may execute. PGRST203
  // means it found several and cannot choose between them. Every cause is on
  // our side of the wire: a misspelt parameter (`p_booking_base_fare` for
  // `p_booking_base_fee` — §7.1.6), a GRANT that names a signature the
  // function does not have, a migration that was never applied, or two
  // overloads left behind by `CREATE OR REPLACE` changing arity.
  //
  // Telling a customer their ride "may have been removed" when the real cause
  // is a misspelt parameter is not just wrong, it is actively harmful: it
  // blames the user for a deployment defect, invites them to retry something
  // that will never work, and hides the cause from everyone reading the
  // screen. So this branch says what is actually true — we could not complete
  // it — and `isNotFound()` no longer treats it as a missing record.
  else if (_any(lower, [
    'pgrst202',
    'pgrst203',
    'could not choose the best candidate',
    'could not find the function',
  ])) {
    message = 'We could not complete that just now. Please try again in a '
        'moment — if it keeps happening, contact support.';
  // ── Server refusals that mean "not your fault", checked BEFORE the
  // missing-rows branch on purpose -- see the note below.
  //
  // Two of these used to wear the same mask as a missing record, because
    // CATEGORY_NOT_FOUND contains the substring "not found" and the generic
    // branch above matches on that. An administrator setting a price was told
    // "this section may have been removed" — which blames a deployment for a
    // value that was simply wrong, and is false.
    //
    // And the 42703 branch is here because of 0107: admin_save_category_fee
    // named a column that does not exist, so EVERY save died with
    // "column ... does not exist" while the screen reported the fee editor as
    // broken in a way nobody could act on. It is a defect on our side, never
    // the user's, so it must never read as a missing record.
  } else if (_any(lower, [
    'category_not_found',
    'category_id_required',
  ])) {
    message = 'That category is no longer available. Reload the list and '
        'choose another one.';
  } else if (_any(lower, [
    'only_the_owner_can_change_fees',
    'fee_settings_can_only_be_viewed_by',
  ])) {
    message = 'Only the account owner can change what the platform charges.';
  } else if (_any(lower, [
    'city_name_is_not_a_city_name',
  ])) {
    message = 'That is not a city name the platform recognises.';
  } else if (_any(lower, [
    '42703',
    'undefined_column',
    // An undefined_column arrives from PostgREST with the message but not
    // always the SQLSTATE in the text the client stringifies, so the message
    // itself is matched too. This makes the not-found branch's own
    // 'does not exist' arm unreachable, which is the correct outcome: when a
    // query says something does not exist it is naming a SCHEMA object on our
    // side, never a customer record of theirs.
    'of relation',
    'does not exist',
  ])) {
    message = 'We could not save that because of a problem on our side. '
        'Nothing was changed — please tell us, and try again later.';
  } else if (_any(lower, [
    'a_reason_is_required',
    'a_warning_needs',
  ])) {
    message = 'Please write a short reason first.';
  }
  // ── Missing rows / removed records ──
  else if (_any(lower, [
    '404',
    'not found',
    'pgrst116',
    'does not exist',
  ])) {
    // PGRST116 is what `.single()` raises on zero rows, with the message
    // "JSON object requested, multiple (or no) rows returned" — it contains
    // neither "not found" nor a 404, so without this it would fall through
    // to the malformed-data branch and tell the user the response was
    // unexpected when the real answer is simply "there is no such record".
    //
    // PGRST202 was removed from this list on purpose: it means the CALL could
    // not be resolved, not that the ROW is absent. Keeping it here is what
    // produced "the category may have been removed" for a fee editor whose
    // category was never touched, and a "Ride not found" screen for a rider
    // whose ride could not be created.
    message = 'That item could not be found. It may have been removed.';
  }
  // ── Duplicate / constraint violations ──
  else if (_any(lower, [
    '23505',
    'duplicate key',
    'already exists',
    'unique constraint',
  ])) {
    message = 'That already exists. Please choose a different one.';
  } else if (_any(lower, [
    '23503',
    'foreign key',
    'violates foreign key',
  ])) {
    message = 'This cannot be completed while related records still exist.';
  } else if (_any(lower, [
    '23502',
    'not-null',
    'null value in column',
  ])) {
    message = 'Please fill in all the required fields.';
  }
  // ── App-specific sentinels that carry their own user-facing meaning ──
  else if (_any(lower, [
    'ride_already_taken',
    'already claimed',
  ])) {
    message = 'This ride was just taken by another driver.';
  }
  // The pre-order availability gate's refusal (migration
  // 20261006000006): create_order_secure raises
  // AVAILABILITY_CONFIRMATION_REQUIRED: <product id> when an order is
  // submitted without an ACCEPTED, unexpired, unused request for a product.
  // The buyer's next action is the gate itself, so the sentence names it.
  else if (_any(lower, [
    'availability_confirmation_required',
  ])) {
    message = 'The provider has not confirmed this item is available yet. '
        'Ask "Is this product available?" first — once they say yes, '
        'you can pay.';
  }
  // ── Bank accounts only (migration 20261006000007) ──
  //
  // Each code is raised by enforce_payment_account_rules or the phone-scan
  // triggers; the sentence tells the provider the one thing they can do.
  else if (_any(lower, ['mobile_money_not_allowed'])) {
    message = 'Telebirr, CBE Birr and other mobile money cannot be used '
        'here. Add a bank account instead.';
  } else if (_any(lower, [
    'phone_like_number_not_allowed',
    'phone_like_text_not_allowed',
  ])) {
    message = 'Phone numbers are not allowed in payment details or product '
        'text — buyers and sellers talk inside the app once an order is '
        'placed. Use a bank account number instead.';
  } else if (_any(lower, ['account_limit_reached'])) {
    message = 'You can have up to 3 payment accounts. Remove or deactivate '
        'one first.';
  } else if (_any(lower, ['account_number_required', 'bank_required'])) {
    message = 'Choose a bank and enter its account number to continue.';
  } else if (_any(lower, ['bank_not_found'])) {
    message = 'That bank is no longer available. Pick another one.';
  } else if (_any(lower, [
    'bank_account_length_invalid',
    'bank_account_prefix_invalid',
  ])) {
    message = 'That account number does not match the selected bank\'s '
        'rules — check the digits and try again.';
  } else if (_any(lower, ['no_payment_account'])) {
    message = 'This seller can\'t accept orders yet — they have no payment '
        'account on file. Find another provider.';
  } else if (_any(lower, [
    'ride_request_expired',
  ])) {
    // The 3-minute unclaimed timeout (claim_ride's RIDE_REQUEST_EXPIRED):
    // the driver tapped Accept on a request the server already gave up on.
    message = 'This request just expired — no driver accepted it in time. '
        'The rider has been asked to try again.';
  } else if (_any(lower, [
    'captcha',
  ])) {
    message = 'Please complete the security check and try again.';
  } else if (_any(lower, [
    'storage',
    'bucket',
  ])) {
    message = 'We could not process that file. Please try a different one.';
  } else if (_any(lower, [
    'format',
    'parsing',
    'json',
    'type cast',
    'cast ',
    'rangeerror',
    'stateerror',
    'null check operator',
  ])) {
    // Malformed data from the backend. The user did nothing wrong.
    message = 'We received an unexpected response. Please try again.';
  }
  // ── Administrator: removing a business (admin_delete_provider) ──
  //
  // Refusals an administrator can act on, which until now all fell through to
  // "Something went wrong" — a delete blocked by live orders read as a crash
  // rather than as an instruction, and that is exactly how it was reported.
  // The counts come out of PROVIDER_HAS_OPEN_WORK orders=N rides=M, which is
  // the same measurement the refusal used, so the screen cannot disagree with
  // the server about how much work is open.
  else if (_any(lower, ['provider_has_open_work'])) {
    final match = RegExp(r'orders=(\d+)\s+rides=(\d+)').firstMatch(raw);
    final orders = int.tryParse(match?.group(1) ?? '') ?? 0;
    final rides = int.tryParse(match?.group(2) ?? '') ?? 0;
    final open = <String>[
      if (orders > 0) '$orders open order${orders == 1 ? '' : 's'}',
      if (rides > 0) '$rides open ride${rides == 1 ? '' : 's'}',
    ];
    message = open.isEmpty
        ? 'Nothing was deleted: this business still has open work. Finish '
            'or cancel it first.'
        : 'Nothing was deleted: this business still has ${open.join(' and ')} '
            '— finish or cancel that work first, so a customer is never left '
            'waiting on a business that no longer answers.';
  } else if (_any(lower, ['provider_already_deleted'])) {
    message = 'This business has already been removed — there is nothing '
        'left to delete.';
  } else if (_any(lower, ['cannot_delete_self'])) {
    message = 'You cannot remove your own business from this screen. Another '
        'administrator has to do it.';
  } else if (_any(lower, [
    'status_cannot_be_self_modified',
    'profile_status_cannot_be_self_modified',
  ])) {
    // Since 20261025000004 an administrator passes this guard, so reaching it
    // means the call did not arrive as an administrator at all. Say that
    // rather than blaming the tap.
    message = 'That approval status could not be changed from this account. '
        'Sign in with a full administrator account — if it keeps happening, '
        'send the reference code to support.';
  } else {
    message = _fallback;
  }

  return '$prefix$message';
}

/// True when [lower] contains any of [needles].
bool _any(String lower, List<String> needles) {
  for (final n in needles) {
    if (lower.contains(n)) return true;
  }
  return false;
}

/// True when [error] means "this record genuinely is not there", as opposed
/// to "the request failed".
///
/// Screens with a dedicated not-found state need this distinction: without
/// it, a dropped connection on a detail page and a deleted record produce
/// the same user-visible screen, and the user is told the thing they were
/// looking for does not exist when it very much does.
///
/// PGRST202 is NOT in this list, and that is the whole point of the note. It
/// means PostgREST could not resolve the call — a wrong parameter name, a
/// missing GRANT, an ambiguous overload. Rendering the not-found screen for it
/// tells the user their ride, product or provider does not exist, when in fact
/// the request never reached the point of asking. It was in this list, and a
/// rider whose ride failed to be created was shown a "not found" page for a
/// ride that was never made.
bool isNotFound(Object error) {
  final lower = error.toString().toLowerCase();

  // NOTE, recorded because it was believed wrong for an hour: the app's own
  // sentinels like CATEGORY_NOT_FOUND do NOT need an exclusion list here,
  // even though they look like they do. The arm below matches the substring
  // 'not found' WITH A SPACE, and the sentinel is 'category_not_found' with
  // an UNDERSCORE, so it never matched in the first place. An exclusion list
  // was added on the assumption that it did, and its own mutation run
  // proved it was dead code -- a guard that guards nothing is worse than no
  // guard, because the next person trusts it.
  //
  // What DID send the fee editor to "may have been removed" is the 42703
  // arm, through 'does not exist', which this list no longer contains.

  return _any(lower, [
    'pgrst116',
    // 'not found' really does stay, and its removal was a regression caught by
    // this file's own mutation run: dropping it made every genuine missing
    // record render an error state instead of a not-found state, which is the
    // failure §7.1.8 was about, reintroduced from the other direction. The
    // exclusion list above is what keeps it safe.
    'not found',
    //
    // 'does not exist' is GONE, and that is the second half of the same fix.
    // A query that says something "does not exist" is naming an object in OUR
    // schema -- a column, a table, a function. The 42703 that broke the fee
    // editor says `column "booking_base_fare" of relation ... does not exist`,
    // and while this arm was here, every detail screen in the app rendered its
    // "not found" state for a request that failed on our side and left the
    // user with a record that was never missing.
    '404',
  ]);
}

/// The server's own refusal code, for surfaces where the code IS the
/// information.
///
/// [friendlyError] deliberately hides codes from end users — `PGRST301` or
/// `42P01` tells a buyer nothing. An administrator diagnosing a moderation
/// refusal needs exactly that, plus the app's own sentinel
/// (`ADMIN_ONLY`, `A_REASON_IS_REQUIRED`, `NO_SUCH_IMAGE`), which PostgREST
/// carries in the exception's `message` field rather than its `code`.
///
/// Returns the two joined (`ADMIN_ONLY · P0001`), the one that exists, or
/// null when the error carries no recognisable code — never an invented one.
/// Dependency-free (dart:core only) so it can be imported anywhere without
/// risking an import cycle, like everything else in this file.
String? errorCodeOf(Object error) {
  final raw = error.toString();

  // PostgrestException(message: ADMIN_ONLY, code: P0001, details: …)
  final message = RegExp(r'\bmessage:\s*([^,)]+)')
      .firstMatch(raw)
      ?.group(1)
      ?.trim();
  final transport =
      RegExp(r'\bcode:\s*([A-Za-z0-9_]+)', caseSensitive: false)
          .firstMatch(raw)
          ?.group(1)
          ?.toUpperCase();

  // `42703: column … does not exist` — the SQLSTATE the transport left in
  // front of the message.
  final sqlstate =
      RegExp(r'^\s*([0-9][0-9A-Z]{4}):').firstMatch(raw)?.group(1);

  // A bare server sentinel (`ADMIN_ONLY`) with no envelope around it.
  final bare = RegExp(r'^\s*([A-Z][A-Z0-9_]{3,})\s*$').firstMatch(raw)?.group(1);

  final parts = <String>[
    if (message != null &&
        RegExp(r'^[A-Za-z0-9_]{4,}$').hasMatch(message))
      message,
    if (sqlstate != null) sqlstate,
    if (bare != null && !(message != null && message == bare)) bare,
    if (transport != null && transport != sqlstate) transport,
  ];
  if (parts.isEmpty) return null;
  return parts.join(' · ');
}

/// [friendlyError] plus the real code — the sentence an ADMIN surface shows.
/// End-user screens keep using [friendlyError] alone.
String friendlyErrorWithCode(Object error, {String? context}) {
  final sentence = friendlyError(error, context: context);
  final code = errorCodeOf(error);
  return code == null ? sentence : '$sentence [$code]';
}
