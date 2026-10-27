# Changelog

All notable changes to Aliob (All In One Business). The version name and
versionCode here match `pubspec.yaml`'s `version:` line and
`lib/core/app_build.dart` (pinned by `test/forced_update_gate_test.dart`).

## 1.9.3+132 - 2026-10-27

## 1.9.3+130 — 2026-10-27

### Delivery

- Delivery tracking and receipt confirmation are live on the server:
  `20261026000002_delivery_tracking_and_receipt.sql` was applied by the
  `Deploy Supabase` run of 2026-10-27 00:09 UTC, so the driver's tracking map,
  the arrival mark and the buyer's "I received it" completion now run against
  the deployed functions instead of an unapplied migration.
- Fixed the self-check that had been stopping that migration: the
  body-flattening pattern was written `E'\s+'`, where PostgreSQL takes an
  unrecognised escape literally, so the pattern was `s+` — every needle
  containing an “s” read as missing and the deploy aborted on its own
  assertion.

### Supabase

- `supabase/DEPLOYED_HEAD` is now
  `20261026000002_delivery_tracking_and_receipt.sql`.
- `20261026000003_the_delivery_assertion_reaches_anon.sql` repairs both halves of
  what the restatement in `20261026000001` broke in
  `assert_delivery_fee_reuses_the_ride_fare()`. It narrowed the grant to
  `authenticated, service_role`, so the connectivity suite — which runs as
  `anon` — could no longer call it and reported it as an unreachable assertion
  (118 passed, 1 failed) rather than as the privilege change it was. It also
  replaced the body's four `E'\\s+'` patterns with five written `E'\s+'`, where
  PostgreSQL takes the unknown escape literally, so the pattern was really `s+`
  and every needle — all of which contain an `s` — read as missing. The body is
  restated with the escaping corrected; only those five lines differ from the
  version it replaces.
- The static harness now applies the same rule the live
  `assert_every_assertion_is_reachable()` guard applies: every zero-argument
  `assert_*` function must end up executable by `anon`. It could not be caught
  before, because the suite reaches these functions by name only through the
  database, so no scan of the Dart saw it.

## 1.9.2+129 — 2026-10-26

### Delivery

- A delivery is priced as a base fee plus a per-kilometre rate against the
  order distance, capped, instead of a flat fee.
- The pickup point is revealed on the map only once the driver marks arrival,
  and the number on that sheet is callable.
- End to end: an administrator assigns a driver to a paid delivery, the driver
  tracks the job and marks arrival, and the buyer confirms receipt to complete
  the order. Only the order's own buyer may complete a delivery, and only after
  that receipt is recorded.

### Supabase

- `20261026000001_delivery_pricing_is_base_plus_distance.sql` is applied on the
  live database at the time of this release.
  `20261026000002_delivery_tracking_and_receipt.sql` was **not** yet applied —
  its own deploy-time assertion stopped the deploy — so tracking and the
  receipt confirmation were not live until that migration applied
  (see 1.9.3+130, which applies it).
- Fixes to the delivery migrations: account deletion passes the delivery driver
  key, and the delivery distance is cast so `round()` resolves.

## 1.9.1+128 — 2026-10-25

### Admin

- Fixed "Could not delete this provider. Something went wrong." — the
  provider-status guard refused every administrator status write (the same
  wall that blocked suspend/reinstate), so the delete rolled back with no
  usable message. Migration `20261025000004` lets an admin's write reach the
  row, keeps the guard against self-approval for providers, and adds a live
  probe that deletes a real provider through the PostgREST path in CI.
- Delete refusals now say what actually happened: open orders/rides with the
  counts, already deleted, cannot delete yourself, and status changes are
  server-managed. The raw server error and a `Ref AL-…` code are logged for
  admins instead of a bare fallback.

### Notifications

- Migration `20261025000005` measures delivery live instead of assuming it:
  it re-arms the outbox drain if the schedule row vanished, flushes the
  queued backlog into real inboxes at deploy time, and adds a report the
  connectivity suite reads on every deploy (queue depth/age, last drain run
  and its error, what reached the inbox, push tokens and n8n_events
  consumption).

## 1.9.0+127 — 2026-10-25

Release-readiness pass for the production rollout (closed testing completed).

### Assistant (help chat)

- Warmer small talk: greetings, "how are you", "who are you / what can you
  do", thanks and praise, goodbyes, apology and frustration, and bare "help".
- "Repeat that" now echoes the previous answer instead of guessing.
- New answers for the questions new users ask first: what Aliob is, signing in
  and password resets, order status / cancellation / refunds, notifications
  and their settings, privacy and account deletion, and reaching a person.
- Provider answers: documents and verification, posting a listing, and getting
  or keeping customers.
- Customer answers: delivery and booking a service.
- Answers are tailored when the signed-in account is a provider.
- Friendly fallback: an apology plus a clarifying question, four quick-reply
  topics and a one-tap route to a human, instead of a cold "submit an appeal".
- Quick-reply buttons are now driven by the server, so every reply can offer
  them (the greeting, the help menu, FAQ answers and the fallback).
- Typo tolerance extended to cancel / register / upload / notifications.
- Fixed: the bot's "My orders" button pointed at `/user/orders`, a route that
  does not exist (only `/user/orders/:id` does), so the app silently dropped
  it. It now opens the orders tab of the user shell.

### Notifications and provider management

- Notification settings are reachable and work: push on/off (honoured by the
  push sender), with SMS and email preferences stored for when those channels
  ship. The Profile row previously answered "not built yet".
- Listing life-cycle notices to the provider: published, hidden or restored by
  an administrator, and removed.
- Security notices on a new device sign-in and on a password change, once per
  device, decided server-side.
- Admin → Providers: search, status and type filters with counts, sorting,
  pagination, a detail sheet with documents and history, and a guarded delete
  (admin-only, refuses while orders or rides are open, revokes sessions and
  device tokens, hides every listing, writes an audit entry).
- Admin → Availability Requests: search, provider and date filters,
  pagination, a detail sheet, a live pending count on the dashboard, and
  admins are now notified when a request arrives.

### Fixes

- The chat assistant no longer offers a dead route.
- The admin sign-in field no longer shows a placeholder that reads like a real
  account.
- A malformed FAQ pattern (unbalanced group) would have stopped the assistant
  function from loading; caught by the chat harness before release.

### Verification

- `tools/harness/run_all.sh` — 71 checks pass.
- `node tools/test/repo_chat_harness.mjs` — 212 checks pass, including every
  FAQ topic, typo handling, the fallback, and that every link the bot offers
  exists in the app.

## 1.8.0+126 — 2026-10-23

- Push notifications end to end: FCM client, `fcm-dispatch` Edge Function,
  invalid-token cleanup, deep links, and signed release artifacts.
- Session persistence: secure token storage, single-flight refresh, restore
  before routing.
