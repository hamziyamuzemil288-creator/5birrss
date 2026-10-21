// tools/integration_test/connectivity_test.dart
//
// Phase 3: integration-verification safety net (see CONNECTIONS.md).
// Verifies the app's cross-actor connections end to end against the LIVE
// Supabase project.
//
// Most assertions are read-only. A few are WRITE tests: they do the real work
// inside a subtransaction that is always rolled back (the function raises a
// sentinel to force the unwind), so real rows with real triggers are
// exercised and nothing is left behind. Those exist because the read-only
// ones pass vacuously when a whole feature is dead — see the
// assert_recent_approved_recharges_credited note below.
//
// Run:   flutter test tools/integration_test/connectivity_test.dart \
//          --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
// CI:    .github/workflows/connectivity-ci.yml runs it on push/PR and fails
//        the pipeline if any connection is broken.
//
// A missing SUPABASE_URL / SUPABASE_ANON_KEY is a HARD FAILURE (the safety
// net must never silently pass), except on fork PRs where secrets are
// unavailable; there the workflow skips with an explicit notice.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'pending_deploy.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

/// Function names that exist ONLY in migrations newer than [deployedHeadFile].
///
/// A push creates them, but the live database does not have them yet, so a call
/// comes back as PGRST202 "Could not find the function <name> in the schema
/// cache". That error is indistinguishable on its face from a misspelt name or
/// a GRANT that closed the function off — the reported cause of this suite's
/// last red run — so the suite must NOT tolerate the error. It tolerates the
/// NAME, and only when the repo itself proves BOTH halves: no migration at or
/// before the applied head defines it, AND the live database agrees it is
/// absent. A deployed function that fails the same way is a real finding (a
/// typo, or a missing grant) and still fails, exactly as any returned `false`
/// does.
///
/// Empty when the boundary cannot be read, which restores the old strict
/// behaviour instead of inventing a tolerance.
final Set<String> _pendingDeployFunctions = readPendingDeployFunctions();

/// Report a call to a not-yet-deployed function as a SKIPPED test rather than a
/// silent pass: the assertion cannot run until the next `Deploy Supabase`, but
/// that absence is expected, not a defect. Any real failure in the same test
/// still fails it.
void _reportPendingDeploy(String fn) {
  markTestSkipped(pendingDeployNotice(fn));
}

void main() {
  if (_url.isEmpty || _anonKey.isEmpty) {
    // Safety nets must never silently pass: fail loudly so CI surfaces the
    // misconfiguration instead of reporting a green-but-meaningless run.
    fail('SUPABASE_URL / SUPABASE_ANON_KEY missing. Supply them via '
        '--dart-define (see CONNECTIONS.md).');
  }

  late final SupabaseClient client;

  setUpAll(() {
    client = SupabaseClient(_url, _anonKey);
  });

  /// Asks the live database whether `fn` exists for the role this suite calls
  /// as, so a stale [deployedHeadFile] can never turn a real failure into a
  /// skip. A function that is present is never tolerated, even when PostgREST
  /// answered PGRST202 — that combination is exactly a missing-GRANT finding
  /// (migration 20261007000008 exists to catch four of them).
  ///
  /// Probes through the same PostgREST surface as the assertion itself, so the
  /// answer reflects anon's visibility rather than a superuser's. Returns
  /// `null` when the probe cannot be answered, which is treated as "not proven
  /// absent" — a stale marker must not be able to skip anything on its own.
  Future<bool?> _functionExists(String fn) async {
    try {
      final result = await client.rpc('pg_func_exists',
          params: {'p_fn_name': fn});
      return result is bool ? result : null;
    } catch (_) {
      return null;
    }
  }

  /// Whether this failure may be reported as PENDING DEPLOY instead of a
  /// finding. Tolerates only the one case that is genuinely not a defect yet:
  /// the server says the function is not there (PGRST202), the repo says no
  /// migration at or before the applied head defines it, AND the live catalog
  /// agrees it is absent.
  ///
  /// Every other outcome is a real finding — including a deployed function
  /// PostgREST cannot resolve because anon lost EXECUTE (also PGRST202), and a
  /// body error such as PRODUCT_NOT_FOUND for a name that happens to sit past
  /// the head. Both were being relabelled PENDING DEPLOY before the live check
  /// was added.
  Future<bool> _tolerate(String fn, Object e) async {
    if (!isPendingDeploy(e, fn, _pendingDeployFunctions)) return false;
    // The repo says "not deployed"; the live database must agree. `null` means
    // the probe could not answer, which is not proof of absence.
    if (await _functionExists(fn) != false) return false;
    _reportPendingDeploy(fn);
    return true;
  }

  Future<bool> ok(String fn) async {
    try {
      return (await client.rpc(fn)) == true;
    } catch (e) {
      // A function the next deploy creates cannot be asserted yet; a function
      // already on the live database that fails is a real finding (and a
      // misspelt/closed function fails the same way).
      if (await _tolerate(fn, e)) return true;
      rethrow;
    }
  }

  /// For assertions that return an explanatory string rather than a boolean.
  /// The text is the evidence: it carries the live values the assertion just
  /// measured, so the CI log shows what was actually true at that moment
  /// instead of only that something was non-false.
  Future<String?> rpcText(String fn) async {
    try {
      final result = await client.rpc(fn);
      return result is String ? result : null;
    } catch (e) {
      if (await _tolerate(fn, e)) return pendingDeployNotice(fn);
      return null;
    }
  }

  /// [rpcText] with the failure kept instead of discarded.
  ///
  /// `rpcText` collapses three different outcomes into one null: the function
  /// reported a real problem, the function is not executable by the role this
  /// suite calls as, and the RPC threw because the function is missing or its
  /// body raised. Only the first is a finding about the database; the other two
  /// are findings about the test. Reporting them all as `Expected: not null,
  /// Actual: <null>` is what made assert_resilience_is_wired take three deploy
  /// cycles to pin down, and each cycle cost a guess rather than an answer.
  ///
  /// Returns (value, error). Callers assert on `value` and print `error`.
  Future<(String?, String?)> rpcTextDiagnosed(String fn) async {
    try {
      final result = await client.rpc(fn);
      if (result is String) return (result, null);
      return (null, 'returned ${result.runtimeType} ($result), not a String');
    } catch (e) {
      if (await _tolerate(fn, e)) return (pendingDeployNotice(fn), null);
      return (null, '$e');
    }
  }

  group('money: wallet ledger -> admin income (Phase 1)', () {
    test('subscription scheduler is wired (pg_cron -> charge_due_subscriptions)',
        () async {
      expect(await ok('assert_subscription_scheduler_scheduled'), isTrue,
          reason: 'The Phase 1 break: nothing scheduled the monthly fee, so '
              'SUBSCRIPTION_FEE rows were never written and Total Income '
              'stayed 0.00. If this fails, the pg_cron jobs are missing.');
    });

    test('wallet balances equal completed ledger totals (no drift)', () async {
      expect(await ok('assert_income_ledger_consistent'), isTrue,
          reason: 'A balance diverging from sum(net_amount) means some path '
              'moved money without writing the ledger — the bug class that '
              'produced a 0.00 Total Income.');
    });

    test('recent completed rides charged their transaction fee', () async {
      expect(await ok('assert_recent_completed_rides_have_fees'), isTrue,
          reason: 'transition_ride_status must charge the fee on COMPLETED; '
              'a missing row means rides froze before completion (break #2).');
    });

    test('recent started/completed orders charged their transaction fee',
        () async {
      expect(await ok('assert_recent_started_orders_have_fees'), isTrue,
          reason: 'transition_order_status must charge the fee on STARTED.');
    });

    test('recent approved recharges credited their wallets', () async {
      expect(await ok('assert_recent_approved_recharges_credited'), isTrue,
          reason: 'approve_wallet_recharge must write the RECHARGE ledger '
              'row the income summary and wallet UI read.');
    });
  });

  group('ride chain: claim -> progress -> fee (Phase 2 #5)', () {
    test('transition function covers the live ARRIVED/TRIP_STARTED chain',
        () async {
      expect(await ok('assert_ride_transition_covers_chain'), isTrue,
          reason: 'The live function previously raised UNEXPECTED_RIDE_STATUS '
              'for ARRIVED/TRIP_STARTED, freezing rides before COMPLETED so '
              'the ride fee never reached the ledger (break #2).');
    });

    test('every ride status has a transition branch', () async {
      // assert_ride_transition_covers_chain only proves ARRIVED and
      // TRIP_STARTED are handled AT ALL. It says nothing about the other
      // statuses — and DRIVER_EN_ROUTE, a live enum value, had no branch at
      // all, so a ride in it raised UNEXPECTED_RIDE_STATUS on every
      // transition: neither rider nor driver could move it, and no fee was
      // ever charged.
      expect(await ok('assert_ride_chain_has_no_dead_ends'), isTrue,
          reason: 'transition_ride_status has no branch for at least one '
              'non-terminal ride status, so a ride in that state is frozen '
              'and cannot be advanced, cancelled, or completed.');
    });
  });

  group('GPS rides: creation -> claim -> timeout', () {
    test('the ride request write matches the ride_requests table', () async {
      // The reported root cause of "rides are not being claimed": the last
      // create_ride_request restatements INSERTed pickup_lat / requested_at
      // — columns no migration ever created — so every call failed with
      // 42703, the rider saw "problem on our side", and no row ever existed
      // for a driver to claim. This reads the LIVE body and checks every
      // column it writes against information_schema.
      expect(await ok('assert_ride_request_write_matches_schema'), isTrue,
          reason: 'create_ride_request() writes a column ride_requests does '
              'not have (42703) or skips a NOT NULL one (23502) — no request '
              'reaches the database, so nothing can ever be claimed. If this '
              'fails right after a deploy, migration '
              '20261006000005 did not run.');
    });
    test('the ride request notifies through the queue, not the guard',
        () async {
      // Reported as "Could not request this ride. Something went wrong."
      // (Ref AL-A65813). create_ride_request is called by a signed-in rider,
      // so is_server_write() and is_admin() are both false; a direct
      // insert_notification() there trips trg_notifications_security with
      // NOTIFICATIONS_CANNOT_BE_CREATED_BY_CLIENTS and rolls the whole ride
      // back — no row, nothing to claim, and a fallback sentence the mapper
      // does not recognise. Migration 20261008000001 routes both call sites
      // through notify_user(), which queues on a client path. This reads the
      // LIVE bodies, so a restatement that goes back to a direct write fails
      // here instead of on a rider's phone.
      expect(await ok('assert_ride_create_notifies_through_the_queue'), isTrue,
          reason: 'create_ride_request() or notify_best_effort() writes '
              'notifications directly again: on a rider\'s own call the '
              'notification guard raises and rolls the ride back, so no '
              'request reaches the database. If this fails right after a '
          'deploy, migration 20261008000001 did not run.');
    });
    test('two drivers accepting at once: exactly one wins', () async {
      // Write test, rolled back by sentinel: a fulfilment-ready driver
      // claims a real REQUESTED row, a second driver claims the same row and
      // must lose with RIDE_ALREADY_TAKEN without overwriting the first, and
      // exactly one REQUESTED -> CLAIMED history row must remain.
      expect(await ok('assert_ride_claim_race_has_one_winner'), isTrue,
          reason: 'claim_ride() lost its conditional UPDATE on '
              'status = REQUESTED (or stopped reporting the loser), so two '
              'drivers accepting at once can both believe they won.');
    });
    test('unclaimed rides expire after 3 minutes (cron + claim guard)',
        () async {
      expect(await ok('assert_unclaimed_ride_expiry_is_wired'), isTrue,
          reason: 'expire_stale_ride_requests is missing, the 5birr-ride-'
              'request-expiry cron job is not scheduled, or claim_ride no '
              'longer refuses 3-minute-stale requests — a request nobody '
              'answers would stay REQUESTED forever.');
    });
  });

  group('pre-order availability gate: ask before every buy', () {
    test('orders demand an ACCEPTED, unexpired, unused request', () async {
      // The reported defect: buyers reached payment while the provider was
      // never asked whether the item exists. Migration
      // 20261006000006 makes create_order_secure raise
      // AVAILABILITY_CONFIRMATION_REQUIRED per product unless a matching
      // availability_requests row is ACCEPTED, inside its 15-minute window,
      // and not yet consumed — then claims it with used_at so one answer
      // cannot cover two orders. This reads the LIVE function, the cron
      // job, the uniqueness index and the realtime publication entry.
      expect(await ok('assert_preorder_availability_gate_is_wired'), isTrue,
          reason: 'The pre-order availability gate lost a piece: '
              'create_order_secure no longer demands (or can reuse) an '
              'availability request, the 15-minute expiry cron is gone, the '
              'provider can answer twice or late, or the one-active-request '
              'index is missing. If this fails right after a deploy, '
              'migration 20261006000006 did not run.');
    });
  });

  group('no contact before payment: numbers only after the YES (item 7)', () {
    test('the reveal needs an availability YES, anon is locked out, the '
        'thread masks numbers', () async {
      // The reported defect: a "Contact seller" button on the product page
      // and account numbers readable by ANYONE (the reveal RPC was granted
      // to anon so the public product page could call it). Migration
      // 20261006000009 revokes anon, requires a buyer to hold an ACCEPTED,
      // unexpired, UNUSED availability request before any number is
      // returned, and masks phone-shaped tokens in order_messages — with
      // the mask pattern exercised live inside the assertion against
      // 09…/07…/2519… numbers (must mask) and 13-digit bank accounts
      // (must not). If this fails right after a deploy, migration
      // 20261006000009 did not run.
      expect(await ok('assert_no_contact_before_payment'), isTrue,
          reason: 'Account numbers are readable without the provider\'s '
              'YES (or by anon), or the order thread no longer masks '
              'phone numbers — the pre-payment contact channel is back.');
    });
  });

  group('admin content control: hide, delete, audit (item 2)', () {
    test('Hide works for every image table and is reversible', () async {
      // The reported defect: the sheet offered "Hide from public" on every
      // published image, but admin_set_gallery_image_public only knew how to
      // resolve provider_gallery ids — every product photo tap came back
      // NO_SUCH_IMAGE (a dead action), and the gallery chip ignored
      // products.is_active so a hidden listing still read "Public".
      // Migration 20261006000010 resolves the id against all three image
      // tables, flips the switch that table actually uses, and audits the
      // change. If this fails right after a deploy, that migration did not
      // run.
      expect(await ok('assert_image_hide_is_reversible'), isTrue,
          reason: 'Hide/restore lost a piece: it no longer handles all '
              'three image tables, a change stops landing in '
              'moderation_actions, or the gallery still reports a hidden '
              'listing as Public.');
    });
  });

  group('staff attribution: actions -> performance view (Phase 2 #6)', () {
    test('staff_performance uses the real ride ownership column', () async {
      expect(await ok('assert_staff_performance_uses_claimed_by'), isTrue,
          reason: 'ride_requests has no provider_id column — the old query '
              'raised undefined-column and the staff performance view errored '
              'for every staff member (break #3).');
    });
  });

  group('city/GPS: signup city -> scoping (Phase 2 #2)', () {
    test('profiles carry the city column the scoping helpers read', () async {
      expect(await ok('assert_profiles_have_city'), isTrue,
          reason: 'CityService writes profiles.city and the city-scoping '
              'helpers read it; a missing column silently unscopes every '
              'feed.');
    });
  });

  group('user<->provider: order routing (Phase 2 #3)', () {
    test('create_order_secure persists fulfillment + city', () async {
      expect(await ok('assert_create_order_persists_fulfillment'), isTrue,
          reason: 'Checkout fulfillment_mode/delivery_address and city '
              'scoping must survive order creation, or provider queues and '
              'delivery flows lose the data.');
    });
  });

  group('account status stays in sync with provider status', () {
    test('no account is gated by a stale suspension status', () async {
      // suspend_provider set both provider_profiles and profiles to
      // SUSPENDED; unsuspend_provider restored only provider_profiles. The
      // profile stayed SUSPENDED forever and the router — which gates on
      // profiles.status — locked that user out of their own account while the
      // admin panel showed APPROVED.
      final synced = await ok('assert_profile_status_synced');
      if (!synced) {
        try {
          final n = await client.rpc('count_status_mismatches');
          // ignore: avoid_print
          print('accounts with a stale suspension status: $n');
        } catch (_) {
          // Diagnostic is best-effort; the assertion below still fails.
        }
      }
      expect(synced, isTrue,
          reason: 'profiles.status disagrees with provider_profiles.status '
              'for at least one account, so someone is either locked out of '
              'the app or gated as suspended while active. Run '
              'public.count_status_mismatches() for the number affected.');
    });
  });

  group('signup OTP gate', () {
    test('gate keys off verified_at, not attempt arithmetic', () async {
      // The bug this guards: verify_email_otp increments `attempts` on every
      // guess, so a user who typed their code correctly on the third try was
      // told { ok: true } and then rejected at account creation with
      // EMAIL_OTP_REQUIRED. The gate must not infer success from attempts.
      expect(await ok('assert_otp_gate_uses_verified_at'), isTrue,
          reason: 'otp_verified_recently no longer keys off verified_at, so '
              'the signup gate is back to rejecting correctly-typed codes '
              'that needed more than one attempt.');
    });

    test('the OTP gate is a working toggle, in either position', () async {
      // While the Resend email provider is unconfigured the OTP cannot be
      // delivered, so the gate is switched OFF and registration completes
      // into the admin approval queue. The failure that matters here is
      // silent and total: if handle_new_user() stops reading the toggle,
      // every signup fails again with "Database error saving new user" and
      // no account is created to approve. If the gate stops working, "turn
      // the OTP back on when email is configured" becomes a lie.
      final (detail, error) =
          await rpcTextDiagnosed('assert_signup_otp_toggle_is_consistent');
      expect(detail, isNotNull,
          reason: 'the signup_otp_required setting is missing, '
              'handle_new_user() no longer reads it (so registration fails '
              'again while the owner believes the OTP is off), or it no '
              'longer refuses an unverified signup (so re-enabling the OTP '
              'would not restore the gate). Diagnostic: $error');
      // ignore: avoid_print
      print('    signup OTP toggle -> $detail');
    });
  });

  group('posting gate (document verification + wallet minimum)', () {
    test('the gate enforces the admin minimum and the posting fee', () async {
      // Migration 20261006000003 added WALLET_BELOW_MINIMUM to
      // provider_fulfilment_blockers() and the optional posting-fee charge to
      // create_provider_product(). The failure that matters is silent and
      // total: if a later restatement drops either, providers can post with
      // an unfunded wallet or the fee stops being charged and logged with
      // nothing in the app noticing — the assertion reads the live function
      // bodies, so it reports exactly which half came unstuck.
      expect(await ok('assert_posting_gate_is_wired'), isTrue,
          reason: 'provider_fulfilment_blockers() no longer enforces '
              'posting_min_wallet_balance, or create_provider_product() no '
              'longer charges/logs the optional posting_fee with its '
              'idempotency key — the posting gate is half-wired.');
    });
    test('no listing publishes or shows without a payment account', () async {
      // Part 13: the platform collects the money, so a provider has no payment
      // account to publish and nothing to add. Migration 20261016000001
      // removes the now-dead NO_PAYMENT_ACCOUNT branch from create_provider_product
      // and from the products_public_read / search_products visibility paths, and
      // retires the old assertion that was gating the rule we just dropped. The
      // surviving posting gate is documents (where required) + wallet minimum, and
      // the app side still reads that same gate and still points at the right remedy
      // screens. So this test now gates the OPPOSITE shape: a provider WITHOUT an
      // account number must still be able to publish and be found, and the three
      // server surfaces must agree they no longer require one.
      expect(await ok('assert_posting_gate_is_document_and_wallet_not_payment_account'),
          isTrue,
          reason: 'The payment-account posting gate was not fully removed: '
              'create_provider_product still refuses with NO_PAYMENT_ACCOUNT, or '
              'search_products / products_public_read still hide providers without '
              'a payment account, or provider_fulfilment_blockers() (the surviving '
              'server gate) is missing. If this fails right after a deploy, '
              'migration 20261016000001 did not run.');
    });

    test('no posting gate still requires a payment account', () async {
      // The removal above must survive a live read of the server source: the
      // old NO_PAYMENT_ACCOUNT assertion no longer exists and the new
      // document-and-wallet assertion exists and passes.
      final old = await rpcText('assert_posting_requires_payment_account');
      final fresh = await ok('assert_posting_gate_is_document_and_wallet_not_payment_account');
      if (old != null) {
        expect(old, isNot('TRUE'),
            reason: 'the retired payment-account assertion still returns true — '
                'the removal did not finish on the live database');
      }
      expect(fresh, isTrue,
          reason: 'the document-and-wallet gate is not passing on the live '
              'database — migration 20261016000001 did not run.');
    });
  });

  group('Guest browsing reads the public catalogue as anon', () {
    /// The one genuinely-not-a-defect-yet case for this group: the guest
    /// grants live in migration 20261020000001, and until it reaches the
    /// live database anon really cannot make these reads — that is the
    /// pending migration, not a new finding. Same three-condition rule the
    /// function tolerance uses: the reply must be privilege denial, the
    /// granting migration must sit past supabase/DEPLOYED_HEAD, and the live
    /// catalog must agree the assertion that PROVES the grants is absent.
    /// Once deployed, a denied read fails the suite — condition 3 is what
    /// keeps a stale marker from hiding a later revoke.
    Future<bool> _tolerateMissingGuestGrant(Object e) async {
      if (!isPermissionDeniedError(e) && !isMissingFunctionError(e)) {
        return false;
      }
      const fn = 'assert_guest_browse_surface_is_readable';
      if (!_pendingDeployFunctions.contains(fn)) return false;
      if (await _functionExists(fn) != false) return false;
      _reportPendingDeploy(fn);
      return true;
    }

    /// Runs one anon read, tolerating only the pre-deploy grant gap, and
    /// NAMES the read when the server refuses it. Connectivity run
    /// 39680798914 failed with the bare PostgREST stack and
    /// `permission denied for table provider_profiles` — nothing saying
    /// WHICH of the two reads was refused, and the two travel different
    /// policy paths: categories can only reach is_admin(), while the
    /// products read goes through the owns_provider_profile arm and the
    /// product_images embed's nested products policy. A refusal without a
    /// read name cost an hour of ruling out every path in the repo.
    Future<List<dynamic>?> _readOrTolerate(
      String what,
      Future<List<dynamic>> Function() run,
    ) async {
      try {
        return await run();
      } catch (e) {
        if (await _tolerateMissingGuestGrant(e)) return null;
        throw StateError('the guest read of $what was refused: $e');
      }
    }

    test('the fatal home-feed tables are readable by anon', () async {
      // Commit e724344 lets a visitor browse before registering, and the
      // guest home feed reads categories and products DIRECTLY — no
      // try/catch around either one — so a 42501 here is not an empty rail,
      // it is the guest's error screen. RLS decides which rows a guest may
      // see; the table-level GRANT decides whether the query can start at
      // all, and 0011 revoked every table privilege from anon.
      final categories = await _readOrTolerate('categories', () =>
          client.from('categories').select('id').limit(1));
      if (categories == null) return;
      expect(categories, isA<List>(),
          reason: 'anon cannot read public.categories — every guest home '
              'load fails before categories_public_read is ever consulted.');

      final products = await _readOrTolerate(
          'products with its product_images embed',
          () => client
              .from('products')
              .select('id, product_images(id)')
              .eq('is_active', true)
              .limit(1));
      if (products == null) return;
      expect(products, isA<List>(),
          reason: 'anon cannot read public.products with its '
              'product_images embed — the fatal home-feed read fails with '
              '42501 and the guest lands on the error screen.');
    });

    test('the guest gallery rail RPC runs as anon', () async {
      // Best-effort in the app (a caught failure just hides the rail), but
      // the revoke was deliberate in the other direction: 20261010000002
      // removed anon from visible_gallery_for_city (PUBLIC included) while
      // the client kept calling it as a guest — so every visitor's gallery
      // rail was silently empty. The grant in 20261020000001 restores the
      // call; the function's own body still only returns is_active photos
      // owned by an APPROVED provider.
      try {
        final rows = await client.rpc('visible_gallery_for_city', params: {
          'p_city': '',
          'p_limit': 5,
        });
        expect(rows, isA<List>(),
            reason: 'a guest cannot run visible_gallery_for_city — the '
                'home-feed gallery rail renders empty for every visitor '
                '(grant removed by 20261010000002, restored by '
                '20261020000001).');
      } catch (e) {
        if (await _tolerateMissingGuestGrant(e)) return;
        rethrow;
      }
    });

    test('the anon grants are declared, not accidental', () async {
      // The two tests above prove behavior; this one names the missing
      // privilege when behavior regresses, so the failure says which GRANT
      // was lost instead of only which screen broke.
      expect(await ok('assert_guest_browse_surface_is_readable'), isTrue,
          reason: 'anon is missing a privilege the guest home feed reads '
              'directly (categories/products/product_images/provider_gallery/'
              'provider_trust_stats SELECT, or owns_provider_profile/'
              'is_admin/visible_gallery_for_city EXECUTE), a policy helper '
              'lost SECURITY DEFINER and runs its provider_profiles read as '
              'the caller, or one of the three read policies reaches '
              'provider_profiles inline. If this fails right after a deploy, '
              'migration 20261020000001 or 20261021000000 did not run.');
    });
  });

  group('PostgREST embeds are backed by real foreign keys', () {
    test('every relationship the app embeds resolves', () async {
      // supabase_flutter embeds with `select('a, child(b)')`, which PostgREST
      // resolves through a foreign key only. It does not infer a relationship
      // because two tables point at the same auth.users row — so
      // `provider_profiles(profiles(...))` breaks unless a real FK exists.
      //
      // When this fails, the missing pair is worth reporting: a screen whose
      // embed is invalid gets PGRST201 and renders an error (or, before load
      // -failure handling, an empty list that looked like "no data").
      final okEmbeds = await ok('assert_embed_relationships_exist');
      if (!okEmbeds) {
        try {
          final missing = await client.rpc('missing_embed_relationships');
          // ignore: avoid_print
          print('missing embed relationships: $missing');
        } catch (_) {
          // The diagnostic RPC is best-effort; the assertion below still fails.
        }
      }
      expect(okEmbeds, isTrue,
          reason: 'At least one PostgREST relationship the app embeds is not '
              'backed by a foreign key, so those screens error with PGRST201. '
              'Run public.missing_embed_relationships() for the pair names.');
    });
  });

  group('exposure: what the anon key can reach', () {
    test('the staff-job catalogue is session-only', () async {
      // staff_jobs had RLS disabled while list_staff_jobs() was explicitly
      // revoked from anon — so the table published to the public what the
      // function withheld from it. The client reads the catalogue as
      // authenticated (the CEO's staff editor), so the assertion checks both
      // directions: anon shut out, signed-in accounts still able to load it.
      final (detail, error) =
          await rpcTextDiagnosed('assert_staff_jobs_are_session_only');
      expect(detail, isNotNull,
          reason: 'public.staff_jobs is readable with the anon key, or RLS is '
              'on with no SELECT policy at all (which would leave every staff '
              'member with an empty checklist). Diagnostic: $error');
      // ignore: avoid_print
      print('    staff_jobs exposure -> $detail');
    });
  });

  group('exposure: what the anon key can reach', () {
    test('the OTP bypass records no verification', () async {
      // Registration is currently open: no email code, admin approval is the
      // gate. That is only safe because the bypass does NOT stamp
      // verified_at — so switching the OTP back on restores the gate for
      // every address, including everyone who signed up while it was off. A
      // second stamp would exempt those addresses for 24 hours after the
      // flip, invisibly.
      final (detail, error) =
          await rpcTextDiagnosed('assert_otp_bypass_is_scoped');
      expect(detail, isNotNull,
          reason: 'verify_email_otp() can no longer tell a switched-off gate '
              'from a real verification, or it stamps verified_at somewhere '
              'other than the correct-code branch — which would leave every '
              'address that skipped the OTP exempt once it is switched back '
              'on. Diagnostic: $error');
      // ignore: avoid_print
      print('    OTP bypass scope -> $detail');
    });
  });

  group('client-write guards do not block the server', () {
    test('order and notification guards exempt server roles', () async {
      // These guards gate on is_admin() = auth.uid(), which is NULL for
      // anything the server does, so each one rejected the server's own
      // writes.
      //
      // The order INSERT guard is the serious one: it required new.status
      // = 'CREATED', and create_order_secure now inserts PENDING_PROVIDER,
      // so it would reject every order the app creates with
      // ORDERS_MUST_START_AS_CREATED. The notification guard rejected
      // pg_cron, which is what aborts the daily subscription run on its
      // overdue-notification path.
      expect(await ok('assert_client_guards_are_server_safe'), isTrue,
          reason: 'An order or notification write guard is no longer '
              'client-scoped, so the server is refused its own writes — which '
              'means orders cannot be created, or the billing job aborts.');
    });
  });

  group('provider status: server may change it, clients may not', () {
    test('the self-approval guard exempts server roles only', () async {
      // The guard reads is_admin(), which is auth.uid() — NULL for anything
      // the server initiates. So it used to reject the pg_cron subscription
      // job and the subscription-process edge function when they moved
      // provider_profiles.status. The suspend branch is not wrapped in an
      // exception block, so the raise aborted the whole daily run: the first
      // provider needing suspension killed the job and everyone after them
      // was skipped. Auto-suspension had never actually worked, and the
      // reactivation path was silently swallowed.
      //
      // The fix scopes the guard to clients via session_user. Both halves
      // are asserted, because the fix must not become "remove the guard":
      // the client branch has to still refuse a status change.
      expect(await ok('assert_provider_status_guard_is_client_scoped'), isTrue,
          reason: 'prevent_provider_self_privilege_escalation either lost its '
              'session_user exemption (breaking the subscription scheduler '
              'again) or lost the client-side refusal (reinstating '
              'self-approval).');
    });
  });

  group('order creation actually works (write test)', () {
    test('a real order is created and persisted, then rolled back', () async {
      // This is the only test in the suite that WRITES, and it exists
      // because the read-only ones let a 25-minute production outage ship
      // green. When create_order_secure was changed to insert
      // PENDING_PROVIDER while a live trigger still demanded CREATED, every
      // order failed — and the order assertion here was a prosrc grep that
      // never created an order, so it could not have caught it.
      //
      // The function does its work in a subtransaction it always rolls back
      // (raising a sentinel to force the unwind), so it asserts against real
      // rows with real triggers attached and leaves nothing behind.
      expect(await ok('assert_order_creation_writes'), isTrue,
          reason: 'create_order_secure did not produce a real order in '
              'PENDING_PROVIDER with its items, or accepted an order from a '
              'non-approved provider. This is the write path, so this failing '
              'means customers cannot check out.');
    });
  });

  group('the server/client discriminator is correct', () {
    test('a client is never classified as a server write', () async {
      // Every client-write guard decides whether to enforce itself with one
      // shared helper, so this single question has two ways to be wrong and
      // both have already happened:
      //
      //  * 0030 tested current_user inside a SECURITY DEFINER trigger, where
      //    current_user is always the function owner — so every caller,
      //    clients included, read as "the server" and the guards disabled
      //    themselves. That left the wallet balance guard inert.
      //  * 00015/16/17 tested session_user, which PostgREST never changes
      //    from `authenticator` — so edge functions still read as clients
      //    and were refused their own writes.
      //
      // This is behavioural, not a source grep: it evaluates the helper in
      // the caller's own context (a Data API call as anon) and requires the
      // answer to be false.
      expect(await ok('assert_server_write_discriminator'), isTrue,
          reason: 'is_server_write() reports true for an ordinary client '
              'call, so every client-write guard is standing down and a '
              'client can write rows that only the server may write.');
    });
  });

  group('a user cannot approve their own account', () {
    test('a non-admin is refused when they try to set their status to APPROVED', () async {
      // profiles_update_own is FOR UPDATE USING (id = auth.uid()) with no
      // column restriction, so a user can write any column of their own row
      // including status. The guard meant to stop that,
      // prevent_profile_self_privilege_escalation, branched on
      // current_user inside a SECURITY DEFINER trigger — where current_user
      // is the function owner for every caller. It returned on its first
      // line, so the check never ran and any authenticated user could
      // PATCH /rest/v1/profiles?id=eq.<their uid> with {"status":"APPROVED"}
      // and approve their own account. The anon key ships in the app bundle.
      //
      // Every other assertion in this suite reads pg_proc.prosrc, and the
      // inert guard had all the right-looking strings in it. This one
      // performs the attack instead.
      expect(await ok('assert_profile_self_approval_is_refused'), isTrue,
          reason: 'A non-admin was able to set their own profile status to '
              'APPROVED, or profiles.city is no longer writable by its '
              'owner. The first is self-approval of the whole account.');
    });
  });

  group('server-mediated admin actions can authorize', () {
    test('the six edge-function RPCs accept service_role and still refuse clients',
        () async {
      // These RPCs are reached through Edge Functions that build a
      // service-role client after authenticating the caller themselves. Under
      // service_role auth.uid() is NULL, so the guard
      //
      //   admin_can(...) OR p_admin_id IS DISTINCT FROM auth.uid()
      //
      // was true on both halves and raised INSUFFICIENT_PERMISSION on every
      // call, before touching a row. Wallet recharges and the whole provider
      // approval pipeline were dead, silently, with no ledger entry and no
      // audit row to notice.
      expect(await ok('assert_admin_rpc_service_role_access'), isTrue,
          reason: 'One of the six admin RPCs reached through an edge function '
              '(approve_wallet_recharge, approve/reject/request_correction/'
              'suspend/unsuspend_provider) either stopped exempting '
              'service_role — so that admin action fails for everyone — or '
              'lost its client-side permission and identity checks, which '
              'would let any caller perform admin actions.');
    });
  });

  group('wallet crediting actually works (write test)', () {
    test('a real recharge is credited through the service-role path, then rolled back',
        () async {
      // assert_recent_approved_recharges_credited, above, cannot answer this
      // question: it asks whether no approved recharge from the last 7 days
      // lacks a ledger row, which is trivially true when nothing was ever
      // approved. It stayed green through a total outage of the feature.
      //
      // This one reproduces the edge function's context with
      // set_config('role','service_role') and calls approve_wallet_recharge
      // for real — the failure only ever appeared under service_role, so a
      // test that called it as itself would have passed against the broken
      // code. It then checks the balance, the request status and the ledger
      // row, and that a second approval does not pay twice.
      expect(await ok('assert_wallet_crediting_writes'), isTrue,
          reason: 'approve_wallet_recharge did not credit the wallet through '
              'the service-role path (250.00 in, 250.00 balance, one RECHARGE '
              'ledger row, still 250.00 after a second attempt), or a direct '
              'client call was allowed. This is the revenue path, so this '
              'failing means providers cannot be paid at all.');
    });
  });

  group('orders cannot be forged by a client', () {
    test('no non-admin INSERT path exists on orders', () async {
      // orders carried a policy allowing any authenticated user to insert
      // their own row with an arbitrary status, total_amount and
      // provider_id. The anon key ships in the app bundle, so anyone could
      // POST a COMPLETED order to /rest/v1/orders and then use it as a
      // ticket for a fabricated review of any product (reviews.target_id
      // has no FK), plus a bypass of server-side pricing and junk in every
      // admin report.
      //
      // Dropping the policy is safe because nothing inserts into orders
      // except create_order_secure(), which is SECURITY DEFINER and is
      // called by the order-create edge function over service_role.
      expect(await ok('assert_orders_not_client_insertable'), isTrue,
          reason: 'A non-admin INSERT policy exists on orders again, so a '
              'client can forge orders — including COMPLETED ones, which '
              'unlock fabricated reviews on any product.');
    });
  });

  group('suspended providers cannot trade', () {
    test('orders are refused for providers that are not APPROVED', () async {
      // Suspension gated the provider out of the app, hid their products
      // from search, and stopped them publishing — but nothing stopped an
      // order being created against a listing that was already ACTIVE. A
      // saved cart or a direct product link still went through, so a
      // suspended provider kept taking work and still earned the fee.
      //
      // That also made non-payment pointless: get suspended for an unpaid
      // subscription fee, then keep trading regardless.
      expect(await ok('assert_orders_block_unapproved_providers'), isTrue,
          reason: 'create_order_secure no longer refuses providers that are '
              'not APPROVED, so a suspended provider can still receive and '
              'be paid for orders.');
    });
  });

  group('order lifecycle has no dead ends', () {
    test('every order status can be advanced out of', () async {
      // Two dead ends lived here for a long time and neither was covered:
      //
      //  * orders were created as CREATED and nothing ever moved them —
      //    the provider had no Accept button and the buyer no transition,
      //    so no order could leave CREATED;
      //  * PAYMENT_VERIFICATION could only be left by an admin, and no admin
      //    screen existed for it, so a customer who had paid sat there
      //    forever and the provider never got APPROVED to start work.
      //
      // The check asserts both that each non-terminal status has an onward
      // branch, and that PAYMENT_VERIFICATION is restricted to an admin OR the
      // order's own provider — the second is an assertion of the restriction,
      // because loosening it to the BUYER would let a customer approve their
      // own payment. (Migration 20260930000001 added the provider, who is the
      // party the money was actually transferred to; the buyer stays out.)
      expect(await ok('assert_order_chain_has_no_dead_ends'), isTrue,
          reason: 'transition_order_status no longer lets every order status '
              'be advanced, or no longer restricts PAYMENT_VERIFICATION to an '
              'admin or the order\'s provider. Either way an order can get '
              'stuck, or a buyer can approve their own payment.');
    });
  });

  group('reactivation restores a provider\'s whole account', () {
    test('vehicles go back in service when a provider is reactivated',
        () async {
      // Suspension is three parts: provider_profiles.status,
      // profiles.status, and vehicles.is_available. The revenue-driven
      // reactivation only undid the first two, so a provider whose fee was
      // collected after an admin suspension was left APPROVED everywhere the
      // UI reads it, but their vehicle stayed unavailable — and an
      // unavailable vehicle is filtered out of find_nearby_drivers() and
      // refused by claim_ride(). Approved, unsuspended, fully paid, and
      // unable to take a single ride, with nothing on screen explaining it.
      expect(await ok('assert_vehicle_sync_handled'), isTrue,
          reason: 'sync_profile_status_from_provider() no longer returns '
              'vehicles.is_available to true on reactivation, so a reactivated '
              'provider stays unable to take rides. The trigger must handle '
              'both halves of a suspension, not just the account status.');
    });
  });

  group('identity documents tell the truth (profile "Verified" bug)', () {
    test('a document has a real admin review lifecycle', () async {
      // The profile tile reported a fixed "Verified" for everyone. The cause
      // was upstream: the status CHECK constraint allowed only MANUAL_REVIEW,
      // AUTO_APPROVED and SUSPECTED_FRAUD, so an administrator had no value to
      // write when they approved an ID — and the client read "a document
      // exists" as "verified". Both halves have to hold: the enum must carry
      // VERIFIED/REJECTED, and provider_docs_satisfied() must still count a
      // VERIFIED document, or approving an ID closes the very gate it was
      // meant to open.
      expect(await ok('assert_document_review_is_admin_only'), isTrue,
          reason: 'review_user_document() is not admin-only, or does not '
              'really write verification_status, or provider_docs_satisfied() '
              'no longer counts a VERIFIED document — so either users can '
              'self-verify or approving an ID locks the provider out.');
    });

    test('a user cannot verify their own document, an admin can', () async {
      // Behavioural, and the half a source-text check cannot do: 0029/0030/
      // 0033/0034 all shipped guards that MENTIONED their condition and never
      // ran it, and the suite was green the whole time. This performs the
      // attack, then requires the legitimate path to succeed — removing
      // the admin check would pass an attack-only test and break the feature.
      expect(await ok('assert_document_review_refuses_non_admins'), isTrue,
          reason: 'Either an ordinary user can mark their own ID VERIFIED, or '
              'an administrator cannot verify one at all, or a verified '
              'document leaves provider_docs_satisfied() false.');
    });

    test('the Other document type records what the document is', () async {
      // Migration 0099's assertion. OTHER plus other_document_label is the
      // schema half; the CHECK pairs them (label exactly when OTHER), the
      // insert policy still lets the client write rows, and the verification
      // trigger still leaves client fields alone. If the gate map ever grows
      // OTHER, the identity gate would open on an unproven document — the
      // Dart-side half of that guard lives in the static harness.
      final (detail, error) =
          await rpcTextDiagnosed('assert_other_document_type_is_wired');
      expect(detail, isNotNull,
          reason: 'user_documents lost the other_document_label column or its '
              'pairing constraint, the insert policy changed, or the BEFORE '
              'INSERT trigger now overwrites client fields. If this is null '
              'WITH the function present, read the error: cache vs finding. '
              'Diagnostic: $error');
      // ignore: avoid_print
      print('    other document type -> $detail');
    });
  });

  group('staff accounts can actually sign in', () {
    test('every linked staff member has a gateway username', () async {
      // "I created the staff in the admin interface and the login says
      // invalid login or username." link_staff_user attached an auth account
      // and told the operator "$email can now sign in as staff" — while
      // creating no staff_credentials row, which is the only thing
      // staff-login looks the typed name up in. Every linked staff member was
      // permanently locked out, and the non-CEO create path still is.
      expect(await ok('assert_staff_link_gets_a_login'), isTrue,
          reason: 'At least one staff row with an auth user has no '
              'staff_credentials row, so staff-login cannot find it and the '
              'account is unreachable. link_staff_user() must write the row '
              'and refuse a username collision rather than skip it.');
    });
  });

  group('the CEO can manage the team, and the team sees it happen', () {
    test('a warning is admin-only, from both doors', () async {
      // The word "warning" did not exist anywhere in this schema. A manager
      // whose only options were silence and revocation had neither, which is
      // why the console could "control" a staff member only by removing their
      // access. Checked behaviourally because the shape that matters — a
      // client writing the row directly, or calling the RPC — is exactly the
      // one a source-text check cannot answer.
      expect(await ok('assert_staff_warnings_are_admin_only'), isTrue,
          reason: 'A non-manager can write a staff warning (directly or '
              'through warn_staff), or can acknowledge a warning that is not '
              'theirs — which would make the acknowledged_at column prove '
              'nothing.');
    });

    test('the CEO can set a staff member\'s city, salary and job role',
        () async {
      // Without this the City -> staff drill-down and every city payroll
      // subtotal stay permanently empty. The columns existed and the payroll
      // report read them, but nothing in the app could write them: the staff
      // form writes through the CEO-gated creation RPC, and adding parameters
      // there means restating a SECURITY DEFINER function full of hierarchy
      // guards. So the report rendered "no staff are assigned to a city yet"
      // forever, which looks like an empty company rather than a missing wire.
      //
      // Checked by REPORT rather than by asserting a boolean, and the error is
      // printed: a null here means either a real finding or that the assertion
      // itself could not run, and those two must not look the same — that
      // ambiguity cost three deploy cycles on assert_resilience_is_wired.
      final (value, error) =
          await rpcTextDiagnosed('assert_ceo_staff_terms_is_wired');
      expect(value, isNotNull,
          reason: 'ceo_set_staff_terms() is missing, or one of the three '
              'columns it writes (city / salary_birr / job_role) was renamed, '
              'or ceo_payroll_report() no longer reads them. Error: $error');
    });

    test('the CEO authority itself is still wired', () async {
      // Migration 69's own assertion, and until now nothing called it. It
      // checks the three things the CEO workspace rests on and none of which
      // this suite reached otherwise: is_ceo() still exists (a dropped or
      // renamed function would silently lock the owner out of every CEO-only
      // action), staff.is_ceo still exists (the column the REAL definition
      // reads — is_ceo() would keep compiling and quietly return false for
      // every CEO staff row if it were renamed), and admin_history still
      // exists as somewhere to record a deletion.
      final (detail, error) =
          await rpcTextDiagnosed('assert_ceo_authority_is_wired');
      expect(detail, isNotNull,
          reason: 'assert_ceo_authority_is_wired() could not run at all. '
              'Error: $error');
      expect(detail, isNot(contains('CEO_AUTHORITY_NOT_WIRED')),
          reason: 'The CEO authority has been dismantled: $detail');
    });

    test('the CEO payroll and finance reports are CALLED, not just present',
        () async {
      // The gap this closes: the suite proved ceo_payroll_report() EXISTS and
      // never called it, so migration 69's first deploy shipped a
      // ceo_city_finance() that read pp.provider_city — a column on
      // support_tickets, not on provider_profiles — and the 42703 was found by
      // a human reading the deploy log. A catalogue check cannot see a
      // function that exists, is wired, and raises the first time somebody
      // opens the Finance tab. This assertion calls both reports and checks
      // every key lib/features/ceo/ceo_dashboard.dart reads, so a rename, a
      // dropped join or a vanishing column fails HERE, on the deploy that
      // ships it.
      final (detail, error) =
          await rpcTextDiagnosed('assert_ceo_reports_are_callable');
      expect(detail, isNotNull,
          reason: 'assert_ceo_reports_are_callable() could not run at all, so '
              'nothing verified the CEO reports. Error: $error');
      expect(detail, isNot(contains('CEO_REPORTS_NOT_CALLABLE')),
          reason: 'A CEO report raised, returned NULL, or lost a key the '
              'workspace reads: $detail');
    });

    test('staff jobs are assignable, and customer ordering is not', () async {
      // staff.permissions was a text[] behind a CHECK naming nine fixed
      // strings, so "assign a job" meant editing a constraint and the Flutter
      // screen carried a third copy of the same list in Dart. It is now a
      // catalogue the CEO picks from, with the product rule — staff never act
      // on a customer's order — as DATA rather than as an accident of which
      // nine keys someone happened to type.
      expect(await ok('assert_staff_job_rules_hold'), isTrue,
          reason: 'set_staff_jobs() must refuse an unknown job, refuse a job '
              'that touches a customer order, grant a real one, keep the '
              'history row when it is removed, and refuse a non-manager.');
    });

    test('the CEO can add a job, not just pick from a seeded list', () async {
      // The catalogue was still, in practice, fixed: ten rows in a migration.
      // Picking a job became easy, but CHOOSING WHICH jobs exist still needed
      // a deploy — so the set was frozen one layer above the CHECK constraint
      // that was removed to unfreeze it.
      expect(await ok('assert_staff_jobs_are_creatable'), isTrue,
          reason: 'create_staff_job() must refuse a non-manager, derive a safe '
              'key from a label alone, and produce a job that can be assigned '
              'immediately; deactivate_staff_job() must refuse while anybody '
              'holds the job and keep the assignment history once they do '
              'not.');
    });

    test('storage writes stay in the caller\'s own folder', () async {
      // Migration 0033 created a second, looser set of policies on three
      // private buckets, and RLS policies OR together -- so the looser set won.
      // One of its disjuncts was a copy-paste from the wrong bucket, letting
      // any signed-in user write outside their own folder in a private
      // bucket. Not readable back, so not a leak, but it breaks the {uid}/
      // invariant every document path depends on.
      //
      // The same migration also replaced product_images_insert with
      // WITH CHECK (bucket_id = 'product-images') and no path check, which the
      // assertion could not see: it read pg_policies.qual, and an INSERT
      // policy has no USING clause, so its rule -- all of it -- is invisible
      // there. product-images is a PUBLIC bucket, so the consequence was not a
      // leak but a write: any signed-in account could overwrite any provider's
      // listing photo, and buyers would be served it immediately. Both halves
      // are covered now.
      expect(await ok('assert_bucket_writes_are_owner_scoped'), isTrue,
          reason: 'A write policy on user-documents, payment-screenshots, '
              'payment-proofs or product-images is not scoped to the caller''s '
              'own folder, or one of them also allows a path in a different '
              'bucket. 0033 shipped both mistakes -- the second as a copy-paste '
              'in the private buckets, and the first as a public bucket anyone '
              'could write to.');
    });

    test('every bucket the app uses exists, and is as visible as it claims',
        () async {
      // provider_gallery_screen.dart uploads to `provider-gallery`, and that
      // bucket is created by exactly one migration — 0017 — which sits in the
      // version range the deploy workflow marks applied WITHOUT executing it
      // (the `Baseline migration history` step of deploy-supabase.yml). 0033
      // then re-created the four buckets the app did have, which is why a
      // gallery could be built, reviewed and shipped against a bucket that was
      // never there: every upload failed with "Bucket not found" (404) and the
      // screen could only show its generic upload error.
      //
      // The policy-shape assertion next to this one could not see it: a bucket
      // with no policies and a bucket that does not exist look identical to a
      // check that only reads pg_policies. This one reads storage.buckets
      // through a SECURITY DEFINER function, because no client role can reach
      // that table, and it fails BOTH ways — a public bucket that should be
      // private leaks documents.
      final (detail, error) =
          await rpcTextDiagnosed('assert_app_buckets_exist');
      expect(detail, isNotNull,
          reason: 'assert_app_buckets_exist() could not run, so nothing '
              'verified that the buckets the app writes to exist. '
              'Diagnostic: $error');
      expect(detail, isNot(startsWith('FAIL')),
          reason: 'A bucket the Flutter client writes to or fetches from is '
              'missing, or its visibility is the opposite of what the app '
              'expects: $detail');
      // ignore: avoid_print
      print('    app buckets -> $detail');
    });

    test('the provider photo surface is complete and still safe', () async {
      // The provider had no photo and no way to put one there: no column, no
      // bucket, and a public page that rendered a bare gradient. This asserts
      // the whole surface at once, and the view column SET rather than the
      // view's existence -- the view is rebuilt in this migration because
      // CREATE OR REPLACE VIEW cannot add a column, so it is the one
      // destructive statement here, and a view that quietly lost a column
      // would break the public provider page with no other symptom.
      final (detail, error) =
          await rpcTextDiagnosed('provider_photo_surface_report');
      expect(detail, isNotNull,
          reason: 'provider_photo_surface_report() could not run, so nothing '
              'verified the provider photo surface. If this is null WITH the '
              'function deployed, read the error: cache vs finding. '
              'Diagnostic: $error');
      // ignore: avoid_print
      print('    provider photo surface -> $detail');

      // `ok()`, not rpcTextDiagnosed(): this assertion RETURNS BOOLEAN, and
      // the text helper rejects a non-String with "returned bool (true), not
      // a String" -- which reads like the database refused to answer, when in
      // fact the assertion had already passed. The report above carries the
      // diagnosis; this only has to carry the verdict.
      expect(await ok('assert_provider_photo_surface_is_wired'), isTrue,
          reason: 'The provider photo surface is incomplete or unsafe. The '
              'report above names which part: the column, the bucket or its '
              'visibility, the storage policies, or the public view.');
    });

    test('the activation fee is withheld and recorded as income', () async {
      // The bug this closes: the registration/activation fee was collected on
      // the provider's first approved recharge -- approve_wallet_recharge
      // wrote a RECHARGE row carrying the withheld amount in platform_fee --
      // but the admin income summary read only TRANSACTION_FEE and
      // SUBSCRIPTION_FEE, so it rendered a confident ETB 0.00 while the money
      // was in the ledger. The read-only money net could not see it either:
      // assert_recent_approved_recharges_credited checks that a recharge was
      // CREDITED, and the activation-fee branch is the one recharge that is
      // deliberately credited LESS than it was charged.
      //
      // This is a WRITE test: it drives the real approved-recharge path inside
      // a subtransaction that always rolls back, with registration_fee_paid
      // = false so the withholding branch is actually exercised, and it reads
      // provider_registration_fee rather than hardcoding the amount.
      expect(await ok('assert_activation_fee_writes_income'), isTrue,
          reason: 'approve_wallet_recharge no longer withholds the '
              'registration fee from the first approved recharge, or no '
              'longer records it as platform_fee on the RECHARGE ledger row, '
              'so the fee is collected but invisible to income reporting.');
    });

    test('the income report counts every fee type, and says what it sees',
        () async {
      // assert_income_covers_every_fee_type() returns a diagnostic STRING
      // rather than a boolean, so the CI log carries the live figures -- how
      // many of each fee type exist, how much the activation fee has actually
      // collected, and whether any arithmetic is impossible. It FAILS for bad
      // arithmetic (a negative platform_fee, a fee larger than the gross) and
      // for a RECHARGE that short-changed a provider without recording the
      // withheld amount as a fee. It REPORTS, rather than fails, an activation
      // fee that is switched on but has never fired on this deployment, since
      // that is a state a fresh project is legitimately in.
      final (detail, error) =
          await rpcTextDiagnosed('assert_income_covers_every_fee_type');
      expect(detail, isNotNull,
          reason: 'assert_income_covers_every_fee_type() could not run, so '
              'nothing verified that income reporting covers every fee path. '
              'Diagnostic: $error');
      expect(detail, isNot(startsWith('FAIL')),
          reason: 'Income reporting does not cover every fee type, or the '
              'ledger contains impossible arithmetic: $detail');
      // ignore: avoid_print
      print('    income coverage -> $detail');
    });

    test('REPORT: the client write surface', () async {
      // A diagnostic, not an assertion. It prints so the next run shows the
      // LIVE state of what a client can write, which cannot be read from the
      // migration files -- a policy created in 0002 and dropped in
      // 20260927000014 is visible in both, and only the database knows which
      // won.
      //
      // This is deliberately print-only on the NUMBERS. Failing the build on a
      // count nobody has read yet would turn the pipeline red for a reason
      // nobody can act on. Once the report has been read and the unexpected
      // entries triaged, the numbers become the contract and this becomes a
      // real assertion.
      //
      // It is NOT silent about the report itself failing, which is what it used
      // to do. The first run of this test went green while the report printed
      // "relation public.objects does not exist" -- the whole point of the
      // work produced no output and nothing noticed. A broken safety net must
      // not read as good news, so the call is unguarded and the report must
      // return one row per kind.
      final rows = await client.rpc('client_write_surface_report');
      expect(rows, isA<List>(), reason: 'client_write_surface_report did not '
          'return a list -- the report is broken, and a broken report is the '
          'finding, not a pass.');
      final byKind = <String, List<String>>{};
      for (final row in (rows as List)) {
        final r = Map<String, dynamic>.from(row as Map);
        byKind['${r['kind']}'] = (r['tables'] as List?)?.cast<String>() ?? const [];
      }
      for (final kind in const ['expected', 'unexpected', 'unguarded']) {
        final names = byKind[kind];
        // ignore: avoid_print
        print('WRITE SURFACE [$kind] (${names?.length ?? -1}): ${names?.join(', ')}');
        expect(names, isNotNull,
            reason: 'client_write_surface_report returned no "$kind" row, so '
                'it is not reporting what it claims to. The safety net is '
                'reporting silence as success.');
      }
      expect(byKind['expected'], hasLength(24),
          reason: 'The expected list in client_write_surface_report() is the '
              'contract for what the app writes client-side. It has drifted '
              'from test/client_write_surface_test.dart, which pins 24 '
              '(20 plus banks, client_error_logs, product_likes and '
              'provider_payment_methods).');
    });

    test('REPORT: every client write policy, quoted', () async {
      // The summary buckets classify; this one quotes, because classifying from
      // the catalog went wrong three times: a quoted relation name that does
      // not resolve, a candidate list taken from a view that spans schemas, and
      // -- the one that got here -- reading pg_policies.qual for INSERT
      // policies, whose entire rule lives in with_check. All 21 INSERT
      // policies came back "WIDE" and were about to be treated as findings,
      // including user_roles_admin_write, which is WITH CHECK (is_admin()).
      //
      // All three were invisible to a passing build. This is found only by
      // reading what the output SAYS rather than whether it ran, which is why
      // the report prints and why it fails when it cannot.
      //
      // Judging a policy is a product decision, so this prints both
      // expression columns, the roles the policy applies to, and lets a human
      // read them. The roles are not decoration: `WITH CHECK (true)` that
      // belongs to PUBLIC was the user_roles escalation, and the identical
      // `CHECK: true` on a policy scoped TO service_role is unreachable rather
      // than dangerous. Without the roles the two read the same.
      final rows = await client.rpc('client_write_policy_detail');
      expect(rows, isA<List>(), reason: 'client_write_policy_detail failed; a '
          'broken report is a finding, not a pass.');
      final wide = <String>[];
      for (final row in (rows as List)) {
        final r = Map<String, dynamic>.from(row as Map);
        final roles = '${r['roles'] ?? ''}';
    }
    });

    test('the client write surface is closed, not just reported', () async {
      // The test above prints; this one decides. Turning the report into an
      // assertion is only safe once its numbers have been read, and they now
      // have: the first clean run printed four WIDE rows. Two were real and are
      // fixed in 20260927000046 -- `Service role can insert roles` on
      // user_roles is WITH CHECK (true) on PUBLIC, so any signed-in user could
      // insert themselves an ADMIN row with the anon key that ships in the app
      // bundle and hold every admin policy in the schema, and email_otp_codes
      // let a client seed its own verification row and pass the signup gate
      // without receiving any email. The other two were artifacts of the
      // report's own rule (a missing WITH CHECK means USING for the written
      // row, and a policy no client role reaches is not a finding), and were
      // fixed in the report instead of in the schema.
      //
      // Both halves are asserted together because either alone is insufficient
      // and reports success: a table grant with no write policy still fails in
      // RLS, and a permissive policy on a table a client cannot write is
      // unreachable.
      expect(await ok('assert_client_write_surface_is_closed'), isTrue,
          reason: 'One of three: a client role can write user_roles, '
              'email_otp_codes or order_items again (a user_roles row with '
              'role=ADMIN is is_admin() for every policy in the schema); a '
              'table outside the twenty-plus the app writes became '
              'client-writable; or a write policy a client can reach never '
              'names a caller. Run public.client_write_surface_report() and '
              'public.client_write_policy_detail() for the offending names.');
    });

    test('the payment-gated tables are NOT writable by a client', () async {
      // The same class as the field tables above, caught by the same run.
      // approved_location_for_buyers and payment_approval_screenshots were
      // created with the Supabase default grant and a FOR ALL policy, so they
      // counted as client-writable tables outside the expected list. Neither
      // is written anywhere in lib/: the approved point is set server-side and
      // read through get_approved_location_for_buyer(), and the screenshot
      // decision goes through approve_payment_screenshot()/..._provider().
      // 20260929000002 revokes the default grant. This pins it: a later
      // migration that re-grants, or an ALTER DEFAULT PRIVILEGES, fails here
      // instead of silently re-opening the surface.
      expect(await ok('assert_gated_tables_are_not_client_writable'), isTrue,
          reason: 'approved_location_for_buyers or payment_approval_screenshots '
              'is writable by anon or authenticated, so any client can insert '
              'or edit an approved provider location or a payment-approval '
              'record directly, bypassing the server path that owns those '
              'writes.');
    });

    test('a staff password change leaves a record of who did it', () async {
      // Self-service password change is the one consequential act a staff
      // member can take on their own account, and it wrote nothing anywhere.
      // The subtlety: the Edge Function authenticates as service_role, which
      // carries no JWT, so log_staff_activity's auth.uid() was NULL there. The
      // row still appeared — with no actor, on the table whose whole purpose
      // is saying who did what. Only the actor value can catch that.
      expect(await ok('assert_staff_password_changes_are_audited'), isTrue,
          reason: 'A self-service password change must be recorded in '
              'staff_activity_log against the real actor (not NULL), as an '
              '"access" event, with no password in the detail — and the '
              '4-argument log_staff_activity() must still mean "the caller".');
    });

    test('money and status changes cannot happen unlogged', () async {
      // admin_cash_recharge, admin_wallet_adjustment, approve_wallet_recharge,
      // transition_order_status, transition_ride_status, claim_ride and
      // suspend_provider wrote no audit row at all. The audit is a trigger
      // rather than a hand-written call in each function, because a call only
      // sees the path that contains it — the same action through an Edge
      // Function was logged, through the SQL editor it was not.
      expect(await ok('assert_money_and_status_are_audited'), isTrue,
          reason: 'A money, status, role or identity table has lost its audit '
              'trigger, so it can change with no trace. The assertion names '
              'the tables.');
    });

    test('the staff task feed updates itself', () async {
      // The feed was a snapshot: loaded once in initState with a manual
      // refresh button, on the one screen whose whole job is to say what to
      // work on. The Dart side subscribes to postgres_changes, which is a
      // silent no-op unless the tables are in the publication — 0041 left
      // them out for ride_requests and 20260925210000 had to add
      // driver_status by hand for exactly this reason. This asserts the
      // publication, not the migration text, so a later DROP fails here.
      expect(await ok('assert_staff_task_sources_are_live'), isTrue,
          reason: 'A table behind staff_task_feed() is not in the '
              'supabase_realtime publication, so the staff workspace '
              'subscription is dead and the screen silently stops updating. '
              'The assertion names the offending table.');
    });
  });

  group('notifications, points and rank', () {
    test('the events that matter notify, and the queued ones drain', () async {
      // Four of the seven named events were already notified by the functions
      // that perform them; orders, rides and appeals were silent. Two
      // assertions because there are two failure modes: an event with no
      // notification at all, and a notification written into the queue that
      // nothing ever empties.
      expect(await ok('assert_meaningful_events_are_notified'), isTrue,
          reason: 'A user-meaningful event has lost its notification, or a '
              'notification is being written by hand instead of through '
              'notify_user() — which would fail on every client-side path.');

      expect(await ok('assert_notification_outbox_is_drained'), isTrue,
          reason: 'The notification queue is not scheduled, has a policy, or '
              'is client-writable — a client-writable queue is a '
              'client-writable notification, and an unscheduled one is a '
              'notification nobody ever sees.');
    });

    test('every award path is wired and the ledger is the source of truth',
        () async {
      // The award triggers are the whole feature: without them a completed
      // order, an approved provider, a positive review and an approved
      // recharge all award nothing, and the ledger and the totals drift apart
      // exactly the way a wallet balance and its ledger did before Phase 1.
      expect(await ok('assert_points_awards_are_wired'), isTrue,
          reason: 'An award trigger is missing, an award function no longer '
              'routes through award_points(), or user_points no longer '
              'matches the sum of the points_ledger rows behind it.');
    });

    test('points are convertible at a rate the CEO controls', () async {
      // The conversion is money leaving the points system and entering a
      // wallet, so this checks the setting exists and is usable, that the
      // superseded points_per_trade knob is gone rather than sitting there
      // looking live, and that a signed-in account can actually call the
      // conversion at all.
      expect(await ok('assert_points_conversion_is_configurable'), isTrue,
          reason: 'A points setting is missing or not numeric, the '
              'points_to_birr_rate is outside (0, 1], the dead '
              'points_per_trade key is back, or convert_points_to_wallet() '
              'is not executable by an authenticated account.');
    });

    test('every fee is data-driven, and the charged fee follows the settings', () async {
      // Behavioural, not declarative: assert_fees_are_data_driven() compares
      // the fee the platform would ACTUALLY charge against the arithmetic
      // implied by system_settings, at two magnitudes. A fee hardcoded back
      // into deduct_transaction_fee() fails this instead of quietly charging
      // the wrong amount. The message it returns is printed below, so the CI
      // log carries the real numbers rather than just a pass.
      final detail = await rpcText('assert_fees_are_data_driven');
      expect(detail, isNotNull,
          reason: 'A fee is missing from system_settings (so it is still '
              'code-driven), is negative or non-numeric, the charged '
              'commission no longer equals GREATEST(percent of gross, '
              'minimum), the fee is flat rather than percentage-based, '
              'deduct_transaction_fee() no longer reads the fee from the '
              'settings, the ride fare no longer matches the configured '
              'pricing, or the CEO-only gate on fee writes has been removed.');
      // ignore: avoid_print
      print('    fee evidence -> $detail');
    });

    test('every fee switch actually switches', () async {
      // The four fee_enabled_* switches were stored and inert until migration
      // 73 — the CEO could flip one and nothing at all would happen. A switch
      // that changes nothing is worse than no switch, because it teaches
      // everyone that the fee surface is decorative. This is the assertion that
      // says otherwise out loud: it checks that each of the five functions
      // which applies a charge still reads its switch, and behaviourally checks
      // the two that can be called directly in BOTH directions (on = the
      // settings arithmetic, off = exactly 0). All four default to on, so this
      // passing means the switches are wired, not that they are in any
      // particular position.
      final (detail, error) =
          await rpcTextDiagnosed('assert_fee_switches_are_wired');
      expect(detail, isNotNull,
          reason: 'assert_fee_switches_are_wired() could not run at all, so '
              'nothing verified the fee switches. Error: $error');
      expect(detail, isNot(contains('FEE_SWITCHES_NOT_WIRED')),
          reason: 'A fee switch is stored but inert, or a switched-off fee is '
              'still being charged: $detail');
      // ignore: avoid_print
      print('    fee switch evidence -> $detail');
    });

    test('payment is gated on availability, contact on verified payment',
        () async {
      // Two guarantees that were both promised and neither enforced.
      //
      // Checkout showed payment details and a screenshot upload with
      // nothing in between checking that the provider had the item, the
      // room or the slot. And release_order_contact() — the escrow gate
      // the Terms screen describes — existed since 20260922000001 and was
      // never called by the app, so the release it writes to admin_history
      // never happened.
      //
      // The assertion is behavioural where it can be: it CALLS
      // release_order_contact() and requires it to refuse, rather than
      // grepping its source for a guard that might be a comment. It also
      // pins both new columns to defaulting to false, which is the whole
      // backwards-compatibility argument: a default of true would gate
      // every existing listing and every in-flight order the moment the
      // migration lands.
      //
      // It also requires create_order_secure() to have exactly one
      // signature. Migration 74 shipped a six-argument overload beside the
      // nine-argument one, having copied forward a comment that said the
      // short form still existed; migration 49 had already dropped it, and
      // the pair is the 42725 "function is not unique" shape that
      // assert_no_stale_function_overloads exists to catch. Migration 75
      // dropped it and turned this requirement around.
      final (detail, error) =
          await rpcTextDiagnosed('assert_availability_gate_is_wired');
      expect(detail, isNotNull,
          reason: 'assert_availability_gate_is_wired() could not run at all, '
              'so nothing verified the availability/payment gate. '
              'Error: $error');
      expect(detail, isNot(contains('AVAILABILITY_GATE_NOT_WIRED')),
          reason: 'Payment is not gated on an availability confirmation, or '
              'contact is not gated on a verified payment: $detail');
      // ignore: avoid_print
      print('    availability gate -> $detail');
    });

    test('a confirmed availability can be paid without a second provider '
        'round trip', () async {
      // Migration 74 built the gate and the last link was missing: the buyer
      // could only reach the screenshot upload from PAYMENT_PENDING, and
      // only the provider could move an order there from ACCEPTED. So a
      // gated order sat at ACCEPTED with the accounts on screen and no
      // button anywhere until the provider happened to open their own order
      // list and press "Request Payment" -- the reported "the screenshot
      // page does not appear after the availability confirmation".
      //
      // Migration 85 widened that one transition for the buyer who placed a
      // gated order. This is what stops it being widened back, or widened
      // too far.
      final (detail, error) =
          await rpcTextDiagnosed('assert_gated_buyer_payment_request_is_wired');
      expect(detail, isNotNull,
          reason: 'assert_gated_buyer_payment_request_is_wired() could not run '
              'at all, so nothing verified that a confirmed order is '
              'payable. Error: $error');
      expect(detail, isNot(contains('GATED_PAYMENT_REQUEST_REGRESSION')),
          reason: 'A confirmed availability cannot be paid: $detail');
      // ignore: avoid_print
      print('    gated payment request -> $detail');
    });

    test('a like actually persists, and a dislike replaces it', () async {
      // The reported symptom was a heart that filled and then emptied again.
      // Two independent causes, either of which alone produces it:
      //
      //  * Liking inserted into product_likes, whose AFTER INSERT trigger
      //    updates products.like_count -- and products sits behind
      //    enforce_provider_write_gate, which asked whether the caller owns
      //    the listing. A buyer never does, so every like in the app was
      //    refused with PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED and the
      //    client's bare catch rolled the heart back silently.
      //  * The client never read the user's reaction back, so a product the
      //    user had already liked rendered empty and the first tap toggled
      //    their existing row off.
      //
      // Every like-related check that existed before was a pg_proc.prosrc
      // grep, which is how a database refusing every like looked entirely
      // correct. This one acts as a real buyer and writes for real.
      expect(await ok('assert_likes_persist_and_are_exclusive'), isTrue,
          reason: 'A like did not persist, or its counter was refused, or a '
              'dislike did not replace a like, or NONE left a row behind, or '
              'a user could write a reaction for somebody else. Either a like '
              'cannot be saved at all, or like and dislike are not mutually '
              'exclusive, or the RLS is not doing its job.');
      expect(await ok('assert_provider_write_gate_allows_counter_updates'),
          isTrue,
          reason: 'enforce_provider_write_gate() no longer exempts writes made '
              'from inside another trigger (pg_trigger_depth() > 1), so the '
              'denormalised like/dislike counters are refused again -- which '
              'means no like can be saved -- or the provider check it sits '
              'above has gone and the gate was opened rather than scoped.');
    });

    test('every listing carries its own type, so BUY vs BOOK reads true',
        () async {
      // The report, third time: the shared BUY/BOOK rule was right and read a
      // column nothing ever wrote. `products.listing_type` defaults to
      // 'PRODUCT' and `create_provider_product()` inserts without naming it, so
      // every service the app created was stored as a PRODUCT and therefore
      // read BUY on every card. Migration 20261012000001 adds the derivation
      // from the category, the trigger that stamps it on every write, and the
      // backfill — and this prints the LIVE rows it left behind, because the
      // question was a data question and only the database can answer it.
      final (detail, error) =
          await rpcTextDiagnosed('assert_listing_types_are_true');
      expect(detail, isNotNull,
          reason: 'assert_listing_types_are_true() could not run at all, so '
              'nothing verified that the stored listing_type matches the '
              'listing\'s own category. Error: $error');
      expect(detail, isNot(contains('FAIL')),
          reason: 'A listing carries a type its own category contradicts, so '
              'a service reads BUY: $detail');
      // ignore: avoid_print
      print('    listing types -> $detail');
    });

    test('the error sink, its RLS and the hot-path indexes are wired', () async {
      // The client's ErrorLogger writes here on every crash. If the table,
      // its RLS or a hot-path index is missing, failures become invisible
      // rather than loud — which is the failure mode this test exists to
      // catch, so it cannot itself be a thing that silently passes.
      final (detail, error) =
          await rpcTextDiagnosed('assert_resilience_is_wired');
      expect(detail, isNotNull,
          reason: 'client_error_logs is missing or has RLS disabled (every '
              'crash report is forgeable or unwritable), the append-only '
              'policy was replaced by an UPDATE/DELETE one (a crash report '
              'can be hidden), the flood-guard trigger is not attached, one '
              'of the hot-path indexes was not created, or the authenticated '
              'role has no statement_timeout. Migration 64 shipped this '
              'returning boolean while rpcText() only accepts String, so a '
              'correct database reported as null here; 65 changed it to '
              'RETURNS text. If this is null again WITH the function present, '
              'read the error below before changing anything — it is now '
              'either a genuine finding or a broken RPC, and they are no '
              'longer reported the same way. Diagnostic: $error');
      // ignore: avoid_print
      print('    resilience -> $detail');
    });

    test('the live map is wired: publication, replica identity, marker feed', () async {
      // The reported RealtimeSubscribeException was NOT a missing publication
      // this time — ride_requests has been published since 0041. It was
      // REPLICA IDENTITY: the driver's open-request feed filters on `status`,
      // a non-primary-key column, and Postgres writes only the key into the
      // WAL under the default identity, so the subscribe is rejected with a
      // CHANNEL_ERROR. This asserts both halves stay true, and that the
      // nearby-marker feed is reachable by a session but NOT by anon.
      final detail = await rpcText('assert_live_map_is_wired');
      expect(detail, isNotNull,
          reason: 'ride_requests or driver_status is unpublished or has a '
              'non-FULL replica identity (live tracking would silently stop), '
              'nearby_provider_markers() is missing or not SECURITY DEFINER, '
              'or nearby driver positions became readable by anon.');
      // ignore: avoid_print
      print('    live map -> $detail');
    });

    test('a payment screenshot upload is actually accepted by its bucket', () async {
      // Migration 101's assertion, and the half of this bug that only a live
      // database can answer. The client fix downscales every picker, so the
      // remaining contract is the bucket's own: it must stay PRIVATE (a
      // payment proof readable by anyone who guesses a path is worse than the
      // outage), must keep accepting image/jpeg (every picker re-encodes to
      // it), and must not be lowered below the limit the recharge screen now
      // quotes the provider. Without this, the only evidence the upload
      // works is a provider reporting that it does not.
      final (detail, error) =
          await rpcTextDiagnosed(
              'assert_payment_screenshot_uploads_are_accepted');
      expect(detail, isNotNull,
          reason: 'The payment-screenshot buckets could not be verified at '
              'all. If this is null WITH the function deployed, read the '
              'error: cache vs finding. Diagnostic: $error');
      expect(detail, isNot(contains('SCREENSHOT_')),
          reason: 'A payment screenshot bucket is not safe to upload to: '
              '$detail');
    });

    test('every bucket the app uploads to has a policy that permits it', () async {
      // Migration 0102's assertion, and the hole this whole class of outage
      // fell through. assert_app_buckets_exist() reads storage.buckets, so it
      // reports a bucket healthy when the bucket is there, the right size and
      // correctly private -- while a bucket with no INSERT policy refuses
      // every upload. assert_private_buckets_are_owner_scoped() inspects the
      // policies that EXIST and therefore passes vacuously on a bucket with
      // none. This asks the question an upload actually depends on.
      final (detail, error) = await rpcTextDiagnosed(
          'assert_client_buckets_have_write_and_read_policies');
      expect(detail, isNotNull,
          reason: 'The bucket write/read policies could not be verified at '
              'all. If this is null WITH the function deployed, read the '
              'error: cache vs finding. Diagnostic: $error');
      expect(detail, isNot(contains('BUCKET_')),
          reason: 'A storage bucket the app uploads to is not usable: $detail');
      // ignore: avoid_print
      print('    bucket policies -> $detail');
    });

    test('a provider can read their own gallery rows', () async {
      // Migration 0104's assertion. The gallery's WRITE path was rebuilt
      // post-baseline as SECURITY DEFINER functions and works; its READ path
      // was assumed to be covered by provider_gallery_owner_read, which is
      // defined only in 0014 -- below the baseline, so marked applied without
      // executing. The consequence is the quietest failure in the app: the
      // upload succeeds, the row is written, the screen's own SELECT returns
      // zero rows, and the grid says "No photos yet".
      //
      // Every previously-reported gallery failure was a write or storage
      // story. This asks about the read.
      final (detail, error) = await rpcTextDiagnosed(
          'assert_provider_can_read_their_own_gallery');
      expect(detail, isNotNull,
          reason: 'The gallery read policies could not be verified at all. '
              'If this is null WITH the function deployed, read the error: '
              'cache vs finding. Diagnostic: $error');
      expect(detail, isNot(contains('GALLERY_')),
          reason: 'A provider cannot read their own gallery: $detail');
      // ignore: avoid_print
      print('    gallery reads -> $detail');
    });

    test('the gallery read surface is reported, not just asserted', () async {
      // A REPORT, so this run records what the live database actually has
      // for provider_gallery rather than only whether it is currently valid.
      // Without it, a later regression is indistinguishable from a
      // database that was always correct, and the next session re-diagnoses
      // from scratch -- which is what happened to the write path.
      final (detail, error) =
          await rpcTextDiagnosed('gallery_read_surface_report');
      expect(detail, isNotNull,
          reason: 'gallery_read_surface_report() did not run. '
              'Diagnostic: $error');
      // ignore: avoid_print
      print('    gallery inventory -> $detail');
    });

    test('an OAuth account can be completed to a verifiable profile', () async {
      // Migration 0104's other half. handle_new_user() builds the profile
      // from raw_user_meta_data; Google supplies none of full_name, phone,
      // kebele or street_road, so those accounts arrive unverifiable and
      // the admin reviewing their document has nothing to check it against.
      final (detail, error) = await rpcTextDiagnosed(
          'assert_profile_completion_is_wired');
      expect(detail, isNotNull,
          reason: 'complete_profile() could not be verified. Diagnostic: '
              '$error');
      expect(detail, isNot(contains('PROFILE_COMPLETION_')),
          reason: 'An OAuth account has no way to become verifiable: $detail');
      // ignore: avoid_print
      print('    oauth profile -> $detail');
    });

    test('a provider can read their own wallet and submit a recharge', () async {
      // The other half of migration 0102, and the cause of the reported
      // "Sorry, we couldn't submit your recharge. That item could not be
      // found." wallets_owner_read and the two recharge_requests provider
      // policies are declared only in 0009/0021/0022/0022b, all below the
      // deploy baseline and therefore marked applied WITHOUT being executed.
      // What did reach production on those tables is staff-scoped
      // (20260922000010), which a provider cannot satisfy -- so the wallet
      // select returned zero rows and the client threw its own not-found.
      // This suite never saw it because it authenticates as anon and, for
      // writes, as service_role; both bypass RLS.
      final (detail, error) =
          await rpcTextDiagnosed('assert_owner_can_read_and_write_their_money');
      expect(detail, isNotNull,
          reason: 'The money-path policies could not be verified at all. If '
              'this is null WITH the function deployed, read the error: '
              'cache vs finding. Diagnostic: $error');
      expect(detail, isNot(contains('MONEY_')),
          reason: 'A provider cannot reach their own wallet or recharge '
              'requests: $detail');
      // ignore: avoid_print
      print('    money policies -> $detail');
    });

    test('the CEO delete routes through the one deletion cascade', () async {
      // Migration 0100's assertion. Three invariants that must never slip:
      // delete_user_account stays service_role-only (a client-reachable
      // cascade is every account gone), the new RPCs reach authenticated but
      // never anon, and ceo_delete_user_account CALLS the cascade instead of
      // growing a second implementation beside it. The Dart-side half (the
      // screen, the typed confirmation, the tiles) is the static harness's.
      final (detail, error) =
          await rpcTextDiagnosed('assert_ceo_delete_is_wired');
      expect(detail, isNotNull,
          reason: 'The CEO delete wiring could not be verified at all. If '
              'this is null WITH the function deployed, read the error: '
              'cache vs finding. Diagnostic: $error');
      expect(detail, isNot(contains('CEO_DELETE_REGRESSION')),
          reason: 'The deletion machinery changed shape: $detail');
    });

    test('nothing in the live schema blocks deleting an account', () async {
      // The assertion 0054 should have shipped and did not. A nullable column
      // with no ON DELETE action blocks the delete just as hard as a NOT NULL
      // one, so `delete_user_account` raised 23503 on `audit_logs` for every
      // account that had ever done anything — after the request had already
      // been marked APPROVED. No test noticed, because the flow had never been
      // run end to end against a real account.
      //
      // This asks the LIVE catalog rather than the migration history, so a
      // constraint added by hand in the dashboard (which no file records) also
      // shows up. Migration 0118 ships `account_deletion_blockers()` for
      // exactly this: it walks the cascade closure and reports every key that
      // would still refuse the delete.
      final (detail, error) = await rpcTextDiagnosed('account_deletion_blockers');
      expect(detail, isNotNull,
          reason: 'The blocker check could not be run at all. If this is null '
              'WITH 0118 deployed, the function is missing or PostgREST has not '
              'reloaded — read the error before changing anything, those are '
              'different faults. Diagnostic: $error');
      expect(detail, isNot(startsWith('BLOCKED')),
          reason: 'An account cannot actually be closed while these columns '
              'still hold a NO ACTION or RESTRICT key onto something that dies '
              'with it: $detail');
      expect(detail, startsWith('ok'),
          reason: 'The blocker check answered something unexpected, so it is '
              'not measuring what it claims to: $detail');
      // ignore: avoid_print
      print('    account deletion blockers -> $detail');
    });

    test('every order and ride leaves a document both parties can read',
        () async {
      // 0121. `order_status_history` and `ride_status_history` are an audit
      // trail: who moved the row, when, from which status. They carry no
      // amount, no counterparty and nothing a person could hold, and there was
      // no receipts table at all — so a customer who paid and a provider who
      // shipped had a notification and nothing else.
      //
      // This asks the LIVE triggers, not the migration history: a trigger that
      // exists but is not attached produces documents for nothing and passes
      // every static check.
      final (detail, error) =
          await rpcTextDiagnosed('assert_transaction_documents_are_wired');
      expect(detail, isNotNull,
          reason: 'The check could not be run at all. If this is null WITH '
              '0121 deployed, the function is missing or PostgREST has not '
              'reloaded — read the error before changing anything, those are '
              'different faults. Diagnostic: $error');
      expect(detail, startsWith('ok'),
          reason: 'At least one order or ride status change left no slip, so '
              'the transaction is not documented end to end: $detail');
      // ignore: avoid_print
      print('    transaction documents -> $detail');
    });

    test('content control can take an image down and record why', () async {
      // 0122. Before this there was `suspend_provider()` and nothing else: an
      // administrator looking at a gallery photograph that breaks the terms
      // could leave it up or delete the provider, and the second is far too
      // destructive to reach for over a picture.
      final (detail, error) =
          await rpcTextDiagnosed('assert_content_control_is_wired');
      expect(detail, isNotNull,
          reason: 'The check could not be run at all. If this is null WITH '
              '0122 deployed, the function is missing or PostgREST has not '
              'reloaded — read the error before changing anything. '
              'Diagnostic: $error');
      expect(detail, startsWith('ok'),
          reason: 'The moderation surface is incomplete, or an action was '
              'recorded with no reason — so there is no audit trail for what '
              'was taken down and why: $detail');
      // ignore: avoid_print
      print('    content control -> $detail');
    });

    test('every admin RPC the app calls is callable with the names it sends',
        () async {
      // The two failures that prompted this, in one assertion.
      //
      // Changing an admin's own password always failed because the Edge
      // Function tested `email.isNotEmpty` -- a Dart extension method that
      // does not exist in Deno, so it threw on the way to the change and the
      // request died as a 500. That is a refusal shaped exactly like a policy
      // decision.
      //
      // Saving a category fee was refused with "That item could not be found.
      // It may have been removed." -- which is what friendlyError renders for
      // PGRST202. PostgREST matches named arguments by NAME, so a client
      // sending `p_city` against a function declaring `p_city_name` gets
      // PGRST202, and so does a function whose arity does not match or which
      // `authenticated` may not execute. All three read to a user as a
      // sentence about a missing record.
      //
      // No static check can settle this: the Dart screen, the migration file
      // and the live catalog can all disagree, and only the catalog is what
      // the server will accept.
      final (detail, error) =
          await rpcTextDiagnosed('assert_admin_write_paths_are_reachable');
      expect(detail, isNotNull,
          reason: 'The check could not be run at all. If this is null WITH '
              '0124 deployed, the function is missing or PostgREST has not '
              'reloaded — read the error before changing anything. '
              'Diagnostic: $error');
      expect(detail, startsWith('ok'),
          reason: 'At least one admin RPC is missing, has the wrong arity, is '
              'not executable by the role the app calls as, declares '
              'different parameter names than the client sends (PGRST202), or '
              'shares its name with another overload in public (PGRST203) — '
              'the first three are what the user sees as "That item could not '
              'be found. It may have been removed": $detail');
      // ignore: avoid_print
      print('    admin RPC reachability -> $detail');
    });

    test('every ride and order RPC a CUSTOMER calls is callable', () async {
      // The reported failure was a rider's: "when user try to order ride its
      // saying that function may have been removed". That sentence was
      // friendly_error's not-found branch rendering PGRST202, which means
      // PostgREST could not RESOLVE the call -- never that a record was
      // deleted. The client half is fixed in friendly_error.dart and
      // failure_mapper.dart; THIS is the half that says which of the four
      // causes it is, read from the live catalog.
      //
      // create_ride_request was checked by hand before the migration was
      // written: its eight parameter names match ride_service.dart exactly and
      // 0114 grants it to authenticated. So a red line here means the deployed
      // catalog differs from every migration in the repository -- which no
      // static check can see.
      final (detail, error) =
          await rpcTextDiagnosed('assert_customer_write_paths_are_reachable');
      expect(detail, isNotNull,
          reason: 'The check could not be run at all. If this is null WITH '
              '0125 deployed, the function is missing or PostgREST has not '
              'reloaded — read the error before changing anything. '
              'Diagnostic: $error');
      expect(detail, startsWith('ok'),
          reason: 'At least one ride or order RPC a customer calls is missing, '
              'has the wrong arity, is not executable by authenticated (which '
              'PostgREST reports as PGRST202), declares different parameter '
              'names than the client sends, or shares its name with another '
              'overload in public (PGRST203). This is what a rider saw as '
              '"that function may have been removed": $detail');
      // ignore: avoid_print
      print('    customer ride RPC reachability -> $detail');
    });

    test('the category fee upsert can actually be planned', () async {
      // The failure this exists for: `admin_save_category_fee` set
      // `booking_base_fare` on a table whose column is `booking_base_fee`.
      // PostgreSQL analyses an ON CONFLICT clause BEFORE it executes, so the
      // statement raised 42703 on every single call and the per-category fee
      // editor had never once written a row.
      //
      // Everything already in this repository was green over it. Migration
      // 0124 proved the function EXISTS with the arity and parameter names the
      // client sends. The Dart harness proved the client sends no undeclared
      // key. The fee check proved every field group is rendered AND sent. All
      // three describe the CALL. None of them executes the STATEMENT, and a
      // correctly named, correctly granted, correctly called function can still
      // be unable to run.
      //
      // This assertion EXPLAINs the upsert, which plans without executing and
      // fails on a column that does not exist. No rows, no category, no
      // fee-editor authority needed.
      final (detail, error) =
          await rpcTextDiagnosed('assert_category_fee_save_plans');
      expect(detail, isNotNull,
          reason: 'The assertion could not be run at all. With 0126 deployed '
              'this function exists and is granted to anon; a null here means '
              'the migration has not been applied or PostgREST has not '
              'reloaded. Diagnostic: $error');
      expect(detail, startsWith('ok'),
          reason: 'The category fee upsert does not plan, so it can never '
              'write a row and no fee an administrator sets has ever been '
              'stored. This is the defect reported as "this section may have '
              'been removed": $detail');
      // ignore: avoid_print
      print('    category fee upsert -> $detail');
    });

    test('the image moderation and fee RPCs are all callable', () async {
      final (detail, error) =
          await rpcTextDiagnosed('image_moderation_signature_report');
      expect(detail, isNotNull,
          reason: 'The report could not be run at all. Diagnostic: $error');
      expect(detail, startsWith('ok'),
          reason: 'At least one of the four image-moderation RPCs, or the fee '
              'save, is missing at the signature the client sends, declares '
              'different parameter names, or shares its name with an overload: '
              '$detail');
      // ignore: avoid_print
      print('    image moderation RPCs -> $detail');
    });

    test('a provider photo is public the moment it uploads', () async {
      // Read-only. It cannot distinguish "uploaded but the account is pending"
      // from "uploaded and visible" without a provider account, so it reports
      // both numbers and lets the difference be read rather than guessed at.
      // The report is the instrument: without it, "my photo is not moving to
      // public" has no answer except a guess.
      final (detail, error) =
          await rpcTextDiagnosed('gallery_visibility_report');
      expect(detail, isNotNull,
          reason: 'The report could not be run at all. Diagnostic: $error');
      expect(detail, startsWith('ok'),
          reason: 'The gallery visibility report failed: $detail');
      // ignore: avoid_print
      print('    gallery visibility -> $detail');
    });

    test('a submitted document tells both sides', () async {
      final (detail, error) =
          await rpcTextDiagnosed('document_notification_wiring_report');
      expect(detail, isNotNull,
          reason: 'The report could not be run at all. Diagnostic: $error');
      expect(detail, startsWith('ok'),
          reason: 'A submitted identity document does not reach both sides. '
              'DocumentUploadService writes user_documents directly and there '
              'was no trigger on the table at all, so the person who uploaded '
              'an ID was told nothing and nobody who could review it was told '
              'anything. This also asserts the signature of notify_user_once '
              'that the send depends on, because the send swallows its own '
              'errors: a mismatch there means every notice fails silently and '
              'still reports ok. $detail');
      // ignore: avoid_print
      print('    document notifications -> $detail');
    });

    test('a document submission records where the device was', () async {
      // The liveness signal. A document photo and the location it was
      // submitted from are very hard to fake together, which is the whole
      // point — but it is a SIGNAL only: nothing gates on it, and the
      // upload must still succeed with GPS off (that is why the column
      // carries UNAVAILABLE/NOT_ATTEMPTED rather than being required).
      final (detail, error) =
          await rpcTextDiagnosed('assert_document_liveness_is_recorded');
      expect(detail, isNotNull,
          reason: 'user_documents has lost the GPS liveness columns or their '
              'integrity constraints, so an ID submission records no location, '
              'or the BEFORE INSERT trigger now overwrites the signal, or the '
              'client can no longer insert documents at all. If this is null '
              'WITH the function present, read the error below before '
              'changing anything: it is either a genuine finding or a '
              'PostgREST cache / RPC problem, and they are not the same. '
              'Diagnostic: $error');
      // ignore: avoid_print
      print('    document liveness -> $detail');
    });

    test('the rank ladder is readable and its boundaries behave', () async {
      // The ladder is data the CEO edits. This asserts the stored array is
      // the shape the readers expect and that the boundary is real: at the
      // first threshold an account holds that rung, one point below it holds
      // none — because a ladder that badges a zero-point account makes the
      // whole progress display meaningless.
      expect(await ok('assert_rank_ladder_is_consistent'), isTrue,
          reason: 'rank_tiers is missing, malformed, does not ascend, has a '
              'non-positive first rung, or points_rank_code() disagrees with '
              'the stored ladder at its own boundary.');
    });
  });

  group('staff city scope and per-category fees', () {
    test('a staff city actually stops something, on every surface', () async {
      // The whole point of a staff city is that it FILTERS. A column that is
      // recorded, displayed and never tested is worse than no column at all,
      // because a manager reads the chip on the staff card, believes the
      // queue below it is scoped, and acts on it. Four separate surfaces can
      // each be the one that was missed, so each is named separately — one
      // combined boolean would tell us that "something" is unguarded and not
      // which.
      expect(await ok('assert_staff_separation_survives_city_scope'), isTrue,
          reason: 'The registration queue no longer separates staff from '
              'registered persons once a city scope is applied — so a staff '
              'member shows up in the person list, or a registration the city '
              'does not cover is still queued. The assertion names which '
              'branch lost the guard.');

      expect(
          await ok('assert_staff_city_scope_covers_the_task_feed'), isTrue,
          reason: 'staff_task_feed carries fewer city scopes than category '
              'scopes, so a categorized branch of the staff work queue is '
              'filtered by category but not by city — or '
              'verify_payment_proof no longer enforces the city scope, which '
              'would let a city-scoped person verify another city\'s payment. '
              'The assertion counts both.');
    });

    test('the per-category and per-city fee surface is readable', () async {
      // These are the reports an admin reads to answer "what does a bajaj in
      // Hawassa cost?". If the catalogue cannot be read back, the editor
      // saves settings nobody can verify, and the fee table is a write-only
      // surface with no confirmation that it applied.
      final (detail, error) =
          await rpcTextDiagnosed('category_fee_surface_report');
      expect(detail, isNotNull,
          reason: 'category_fee_surface_report() could not run, so nothing '
              'verifies that the per-category / per-city fee settings are '
              'readable and complete. If this is null WITH the function '
              'present, read the diagnostic before changing anything: it is '
              'either a genuine finding or a PostgREST cache problem, and '
              'those are not the same. Diagnostic: $error');
      // ignore: avoid_print
      print('    category fee surface -> $detail');
    });

    test('the city scope report agrees with the guards that enforce it', () async {
      // The report is what a human reads to answer "is the city scope real".
      // A report that says "wired" while a guard is missing is worse than no
      // report, so this asks the database to count both and compare.
      final (detail, error) =
          await rpcTextDiagnosed('staff_city_scope_report');
      expect(detail, isNotNull,
          reason: 'staff_city_scope_report() could not run, so the city scope '
              'has no readable evidence that it is enforced. Diagnostic: '
              '$error');
      // ignore: avoid_print
      print('    staff city scope -> $detail');
    });

    test('a provider may only work once verified, paid and funded', () async {
      // The product rule: documents verified, activation fee paid, wallet able
      // to cover the platform fee, before posting a listing, adding a vehicle,
      // claiming a ride or accepting an order.
      //
      // Two of those were not true before migration 0113. The document half
      // was satisfied by UPLOADING an ID — provider_docs_satisfied() admits
      // MANUAL_REVIEW, which is the state a document row is born in — and
      // claim_ride and transition_order_status never consulted the gate at
      // all, so an unfunded provider could take a rider's trip. Both are
      // invisible from the client, which is why this asserts the wiring.
      expect(await ok('assert_provider_fulfilment_gate_is_wired'), isTrue,
          reason: 'The fulfilment gate is not fully wired. The named failure '
              'is the one that is true: a surface that hands out work without '
              'consulting the gate, a strict document check that has gone back '
              'to accepting MANUAL_REVIEW ("verified" meaning "uploaded"), or a '
              'blocker that is no longer produced.');
    });

    test('the other side of an order or a ride is told', () async {
      // A notification is the only thing that makes a marketplace reactive.
      // Three of the most important events fired silently: a provider was
      // never told an order arrived, no driver was ever told a ride was
      // nearby, and a rider was never told their ride had a driver. All three
      // "worked" — which is why they survived: the counterparty found out by
      // polling, and polling raises nothing.
      expect(await ok('assert_counterparties_are_notified'), isTrue,
          reason: 'A counterparty is no longer notified. The assertion names '
              'which one: the provider on a new order, the nearby drivers on a '
              'new ride, or the rider on a claim.');
    });

    test('a per-category fee resolves for the case the UI actually asks for',
        () async {
      // The editor's contract: a BLANK field means inherit, and the effective
      // value is shown as a hint that is never seeded into a controller. If
      // the resolver cannot answer for a category with no row of its own, the
      // screen either shows "null" as a price or invents one. This returns a
      // BOOLEAN, so it goes through ok() -- reading it as text would return
      // null and fail as "could not run" on a function that works fine.
      expect(await ok('assert_category_fees_are_wired'), isTrue,
          reason: 'category_fee() does not fall back to the inherited '
              'default, a fee column is NOT NULL where the blank-means-inherit '
              'contract requires NULL, a fee is negative or a commission is '
              'over 100, or a client can still write the fee table directly.');
    });
  });

  group('money and approval notifications', () {
    // Everything in this group is a WRITE test, run inside a subtransaction
    // that is always rolled back. They are not read-only because the property
    // being tested is behavioural: a second call must not write a second row,
    // and a failing insert must not propagate. Neither can be observed by
    // reading the function source.

    test('a money notification is delivered once, and never fatal to the payment',
        () async {
      // Two properties, both of which have silent failure modes:
      //
      //  * A retry (double tap, redelivery) must not notify twice. Deduping
      //    on a key read without a lock races: two calls both see "no existing
      //    row" and both write.
      //  * A notification that cannot be delivered must NOT raise. Inside
      //    approve_wallet_recharge or convert_points_to_wallet that would
      //    roll back a real payment and report it as a failure — the money
      //    would be correct and the user would be told it failed.
      final (detail, error) =
          await rpcTextDiagnosed('assert_notify_user_once_is_idempotent');
      expect(detail, isNotNull,
          reason: 'notify_user_once() could not be exercised, so nothing '
              'verified that a money notification is delivered exactly once. '
              'Diagnostic: $error');
      expect(detail, isNot(contains('NOTIFY_ONCE_')),
          reason: 'A money notification is wrong: $detail');
      // ignore: avoid_print
      print('    notify_user_once -> $detail');
    });

    test('every approval path sends a welcome, and none lost its guards', () async {
      // This is the assertion that has to catch a careless restatement.
      // assert_meaningful_events_are_notified() passed on a body of
      // approve_provider that had lost two of its four authorization
      // conditions: it was written to catch the bug the author expected and
      // was blind to the one they caused. This one names each condition, and
      // additionally fails if some other function approves an account without
      // a welcome.
      final (detail, error) =
          await rpcTextDiagnosed('assert_approval_welcome_covers_all_paths');
      expect(detail, isNotNull,
          reason: 'assert_approval_welcome_covers_all_paths() could not run, '
              'so nothing verified that every approval path notifies. '
              'Diagnostic: $error');
      expect(detail, isNot(startsWith('FAIL')),
          reason: 'An approval path is un-welcomed or was restated without '
              'its guards: $detail');
      // ignore: avoid_print
      print('    approval welcome -> $detail');
    });

    test('both sides of an order and a ride are told what happened', () async {
      // The both-parties requirement. Before this, the provider was told
      // nothing when an order payment was verified, and the rider's messages
      // carried no amount. It also re-checks that all ten status branches
      // still notify, because a restatement that drops an ELSIF is
      // indistinguishable from "nothing happened" to the person waiting.
      final (detail, error) =
          await rpcTextDiagnosed('assert_order_and_ride_receipts_are_sent');
      expect(detail, isNotNull,
          reason: 'assert_order_and_ride_receipts_are_sent() could not run, '
              'so nothing verified that buyers AND providers are both '
              'notified. Diagnostic: $error');
      expect(detail, isNot(startsWith('FAIL')),
          reason: 'An order or ride notification is missing, generic, or '
              'claims a wallet credit that does not happen: $detail');
      // ignore: avoid_print
      print('    order/ride receipts -> $detail');
    });

    test('converting points to birr says so', () async {
      // convert_points_to_wallet() debited the ledger and credited the
      // wallet in silence. The balance changed with no way for the user to
      // find out, and the conversion screen had to render the result itself.
      // This also re-checks the money invariants, because restating a money
      // function is where the advisory lock or the FOR UPDATE balance
      // re-read tends to go missing.
      final (detail, error) =
          await rpcTextDiagnosed('assert_points_conversion_notifies');
      expect(detail, isNotNull,
          reason: 'assert_points_conversion_notifies() could not run. '
              'Diagnostic: $error');
      expect(detail, isNot(startsWith('FAIL')),
          reason: 'The points conversion is silent, unkeyed, or lost a money '
              'invariant in the restatement: $detail');
      // ignore: avoid_print
      print('    points conversion notice -> $detail');
    });

    test('a user can only read their own notifications', () async {
      // The new call sites are SECURITY DEFINER and server-only, but they
      // write rows a client then reads. This is the check that a new function
      // did not quietly widen that: the guard trigger still refuses a client
      // insert, and RLS still scopes the inbox to its owner.
      final (detail, error) =
          await rpcTextDiagnosed('assert_notification_inbox_is_owner_only');
      expect(detail, isNotNull,
          reason: 'assert_notification_inbox_is_owner_only() could not run, so '
              'nothing verified that notifications stay owner-scoped. '
              'Diagnostic: $error');
      expect(detail, isNot(startsWith('FAIL')),
          reason: 'The notifications inbox is no longer owner-scoped: $detail');
      // ignore: avoid_print
      print('    notification inbox scope -> $detail');
    });

    test('every assertion this suite calls is executable by the anon role',
        () async {
      // This suite builds SupabaseClient with the ANON key and no session, so
      // every RPC here runs as `anon`. An assertion granted to `authenticated`
      // only is invisible to it, and PostgREST reports that as PGRST202 "could
      // not find the function in the schema cache" — which reads like a
      // missing migration and sends you looking in the wrong place.
      //
      // Five assertions in this file were unreachable for exactly that reason
      // and failed CI after a clean deploy. This checks the whole assert_*
      // family, so the next one written without anon fails immediately and by
      // name instead of as a confusing schema-cache error.
      final (detail, error) =
          await rpcTextDiagnosed('assert_every_assertion_is_reachable');
      expect(detail, isNotNull,
          reason: 'assert_every_assertion_is_reachable() could not run, so '
              'nothing verified that the assertions in this suite are '
              'reachable. Diagnostic: $error');
      expect(detail, isNot(startsWith('FAIL')),
          reason: 'An assertion in this suite cannot be called by the role '
              'this suite runs as, so it will never pass: $detail');
      // ignore: avoid_print
      print('    assertion reachability -> $detail');
    });

    test('the assertions compare against text that is actually there',
        () async {
      // Every failure in this group so far was in the CHECK, not the checked.
      // Two of these assertions compared pg_proc.prosrc against a hand-typed
      // needle that did not match: one was defeated by where the author had
      // wrapped a line, one had a typo (v_ledgerid for v_ledger_id). Each then
      // reported a defect that did not exist, on every run, until a live run
      // caught it. An assertion whose needle is wrong cannot be caught by
      // anything else, because it is the thing doing the checking.
      final (detail, error) =
          await rpcTextDiagnosed('assert_source_needles_match');
      expect(detail, isNotNull,
          reason: 'assert_source_needles_match() could not run, so nothing '
              'verified that the source-matching assertions are comparing '
              'against text that exists. Diagnostic: $error');
      expect(detail, isNot(startsWith('FAIL')),
          reason: 'An assertion is searching for text its target does not '
              'contain, so it reports phantom defects or passes when it '
              'should fail: $detail');
      // ignore: avoid_print
      print('    source needles -> $detail');
    });
  });

  group('admin screens: the columns they select must exist', () {
    /// Runs a PostgREST select and returns the error, or null if it resolved.
    ///
    /// A missing column raises 42703 here even though RLS hides every row: the
    /// column list is resolved against the catalogue before row visibility is
    /// decided. That is what makes this a probe of the SCHEMA rather than of
    /// the data.
    Future<String?> selectError(String table, String columns) async {
      try {
        await client.from(table).select(columns).limit(1);
        return null;
      } catch (e) {
        return '$e';
      }
    }

    /// A column error is the only failure that matters here. Anything else --
    /// a permission error, an empty result, a network hiccup -- is not a
    /// finding about the schema, and treating it as one would make this a
    /// false red that people learn to ignore.
    void expectNoColumnError(String where, String? error) {
      final isColumnError = error != null &&
          (error.contains('42703') ||
              error.contains('does not exist') ||
              error.contains('PGRST204'));
      expect(isColumnError, isFalse,
          reason: 'The $where screen selects a column the database does not '
              'have, so the whole screen fails to load the first time it is '
              'opened. This is how orders.order_number shipped: migration 0037 '
              'created it, but 0037 is BELOW the deploy baseline, so it was '
              'recorded as applied without ever being executed. Error: $error');
    }

    test('the order payments screen can select its own columns', () async {
      // Verbatim from admin_order_payments_screen.dart.
      expectNoColumnError(
          'admin order payments',
          await selectError(
              'orders',
              'id, status, total_amount, currency, created_at, '
                  'user_id, provider_id, '
                  'payment_proofs(id, storage_path, verification_status, '
                  'created_at), '
                  'provider_profiles!inner(business_name, '
                  'profiles(full_name, phone))'));
    });

    test('the transaction history screen can select its own columns',
        () async {
      // Verbatim from admin_transaction_history_screen.dart.
      expectNoColumnError(
          'admin transaction history',
          await selectError(
              'wallet_transactions',
              '*, provider_profiles(business_name, user_id, '
                  'profiles(full_name, phone)), orders(id)'));
    });

    test('the support ticket fields the screen reads are REPORTED, not judged',
        () async {
      // `select('*')` cannot raise a column error, so this cannot go red -- and
      // a test that cannot fail is not a test. It is here to ANSWER a question
      // instead: the screen reads t['order_number'] and t['provider_city'],
      // both added by migration 0039, which is below the baseline and so was
      // recorded as applied without being executed. A `select('*')` returns no
      // key for a column that does not exist, so those fields would be
      // silently empty rather than broken.
      //
      // Named explicitly, the catalogue answers. Reported rather than asserted
      // because a missing display field is a finding about data shape, not a
      // crash, and failing the suite on it would be a red that blocks a deploy
      // over something no user can see. Same treatment as income coverage.
      final error = await selectError('support_tickets',
          'order_number, provider_city, provider_name, provider_reference');
      // ignore: avoid_print
      print('    support ticket fields -> ${error == null ? 'all present' : error}');
    });
  });

  group('ranking and per-category fields (every trade, best to least)', () {
    test('the ranked provider reader resolves and reports its order', () async {
      // The whole point of the feature: the busiest provider is first. The
      // report carries the live counts, so the log shows what the ranking
      // actually measured rather than only that the function existed.
      final (detail, error) = await rpcTextDiagnosed('ranking_wiring_report');
      expect(detail, isNotNull,
          reason: 'ranked_providers / ranked_categories / '
              'provider_transaction_stats are missing or not executable by '
              'anon, so the home rail, the "All providers" sheet and the '
              'category screen all fall back to signup order. Diagnostic: '
              '$error');
      // ignore: avoid_print
      print('    ranking wiring -> $detail');
    });

    test('the category field catalogue resolves and is seeded', () async {
      // A catalogue that exists but is empty is a provider settings screen
      // with nothing on it -- green in every static check, blank on a device.
      final (detail, error) =
          await rpcTextDiagnosed('category_field_wiring_report');
      expect(detail, isNotNull,
          reason: 'category_profile_fields / provider_profile_field_values or '
              'their reader RPCs are missing, so no provider has a settings '
              'form and the customer page has nothing to show. Diagnostic: '
              '$error');
      expect(detail, startsWith('ok:'),
          reason: 'the field catalogue exists but is not seeded, so every '
              'provider settings form is empty. Report: $detail');
      // ignore: avoid_print
      print('    category field wiring -> $detail');
    });

    test('an anonymous caller cannot write a provider field value', () async {
      // save_provider_value_outcome returns the SQL error it got, or the
      // literal 'ACCEPTED' if the write went through. This suite runs as anon
      // -- no JWT, no provider profile -- so ACCEPTED here means ANY caller
      // can file an answer against any provider.
      final (outcome, error) =
          await rpcTextDiagnosed('save_provider_value_outcome');
      expect(outcome, isNotNull,
          reason: 'save_provider_profile_field is missing or not callable as '
              'anon, so the provider save path cannot be exercised. '
              'Diagnostic: $error');
      expect(outcome, isNot('ACCEPTED'),
          reason: 'a caller with no provider profile was allowed to write a '
              'provider field value, so the value table has no working owner '
              'guard.');
      // ignore: avoid_print
      print('    provider field write outcome -> $outcome');
    });

    test('the field tables are NOT writable by a client', () async {
      // Supabase grants INSERT/UPDATE/DELETE to the client roles by DEFAULT on
      // every new public table, and both field tables carry a FOR ALL policy,
      // so on the first live run after 0128 they counted as client-writable
      // tables outside the expected list and the write-surface assertion
      // refused them. The app writes them only through SECURITY DEFINER RPCs;
      // 0129 revokes the default grant. This pins it: a later migration that
      // re-grants, or an ALTER DEFAULT PRIVILEGES, fails here instead of
      // silently re-opening the surface.
      expect(await ok('assert_field_tables_are_not_client_writable'), isTrue,
          reason: 'category_profile_fields or provider_profile_field_values '
              'is writable by anon or authenticated, so any client can file '
              'or edit a provider field answer directly, bypassing '
              'save_provider_profile_field and its category-membership check.');
    });

    test('the combined assertion passes on the live database', () async {
      // assert_ranking_and_category_fields EXERCISES the paths and returns
      // jsonb with an `ok` flag plus the evidence. A schema that parses and a
      // save that silently writes nothing look identical to every static
      // check in this repository; this is the one place the database answers.
      Object? result;
      String? error;
      try {
        result = await client.rpc('assert_ranking_and_category_fields');
      } catch (e) {
        error = '$e';
      }
      if (error == null) {
        // ignore: avoid_print
        print('    ranking/category assertion -> $result');
      }
      expect(error, isNull,
          reason: 'assert_ranking_and_category_fields is missing or raised, '
              'so the ranking and per-category field paths cannot be '
              'exercised. Diagnostic: $error');
      expect(result, isNotNull,
          reason: 'the assertion returned nothing');
    });
  });

  group('a submitted application tells both sides', () {
    test('the submission and reactivation wiring is live', () async {
      final (detail, error) =
          await rpcTextDiagnosed('registration_notification_wiring_report');
      expect(detail, isNotNull,
          reason: 'The report could not be run at all. Diagnostic: $error');
      expect(detail, startsWith('ok'),
          reason: 'A submitted application does not reach the applicant and '
              'the reviewers. Every signup and every Become a Partner '
              'application converges on one INSERT into approval_requests, '
              'and that table had no trigger at all -- so the person who '
              'applied was never told it was received, and nobody holding '
              'registrations was told one arrived. The same report asserts '
              'that unsuspend_provider still carries all four of its '
              'authorization clauses AND its reactivation notice, because '
              'the 0026 restatement dropped that notice silently. $detail');
      // ignore: avoid_print
      print('    registration notifications -> $detail');
    });

    // registration_review_recipients() is deliberately NOT called from here.
    // It is a list of account ids, so it stays a server-side definition, and
    // the trigger that uses it is SECURITY DEFINER and needs no caller
    // privilege. A test that called it to watch the call fail would name the
    // function in a suite that runs as anon, and the RPC-reachability check
    // would then read the denial as a call with no path and demand a grant
    // that must not exist. The privilege is asserted where it can be seen
    // exactly -- inside the report above, against the live grant.
  });

  group('an appeal reaches the people who can act on it', () {
    test('the appeal notification wiring is live', () async {
      final (detail, error) =
          await rpcTextDiagnosed('appeal_notification_wiring_report');
      expect(detail, isNotNull,
          reason: 'The report could not be run at all. Diagnostic: $error');
      expect(detail, startsWith('ok'),
          reason: 'A filed appeal does not reach the people who have to work '
              'it. fn_notify_appeal_case_filed notified only the person the '
              'case was filed AGAINST, so the accounts that can actually OPEN '
              'the queue -- is_admin() and staff holding support_chat, which is '
              'exactly the set appeal_cases own SELECT policy admits -- were '
              'never told one arrived. The same report asserts that '
              'DOCUMENT_VERIFICATION is admitted by the case_type CHECK: a '
              'person whose ID was rejected had no way to file a dispute a '
              'reviewer could filter on. $detail');
      // ignore: avoid_print
      print('    appeal notifications -> $detail');
    });
  });

  group('closing an account removes the files, not just the rows', () {
    test('the account file sweep is live and reachable by its owner only',
        () async {
      final (detail, error) =
          await rpcTextDiagnosed('assert_account_storage_is_purged');
      expect(detail, isNotNull,
          reason: 'The report could not be run at all. Diagnostic: $error');
      expect(detail, startsWith('ok'),
          reason: 'Deleting an account removes thirty-six tables and none of '
              'the files they pointed at: the identity, business and driving '
              'document scans, every appeal evidence photo, the avatar, the '
              'listing photos, the gallery, the vehicle photos. Nothing in '
              'this project deleted a bucket object on the account path '
              'before migration 0132, so the rows are gone and the files stay. '
              '$detail');
      // ignore: avoid_print
      print('    account file sweep -> $detail');
    });
  });
}
