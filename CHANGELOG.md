# Changelog

All notable changes to Aliob (All In One Business). The version name and
versionCode here match `pubspec.yaml`'s `version:` line and
`lib/core/app_build.dart` (pinned by `test/forced_update_gate_test.dart`).

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
