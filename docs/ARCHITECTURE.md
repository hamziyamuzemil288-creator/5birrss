# Architecture

Aliob is a Flutter + Supabase marketplace and ride-hailing app. This document
describes the app **as it is today**, not as it is meant to be: the layering
that exists, every place the code departs from it, who each role can actually
do what, the two flows that are hardest to hold in your head, what is known
broken, and what must be live for the app to work.

Everything here was checked against the tree at the commit that last touched
this file. Where a claim is machine-checked, the check is named. Where
something could only be read and not run (there is no Dart SDK and no device
in the audit environment), it says so.

---

## 1. The shape, and where it leaks

```
  screens          lib/features/**          user intent + local UI state
        │  MOSTLY no Supabase — but see the exceptions in §1.3
        ▼
  providers        lib/core/providers/**    derived state (auth, mostly)
        │          lib/core/models/**      pure data
        ▼
  services         lib/core/services/**     all I/O: queries, RPC, functions,
        │                                    storage, realtime
        ▼
  Supabase         Postgres + RLS + SECURITY DEFINER functions + Edge Functions
```

There is no repository layer. One existed, nothing traversed it, and it was
deleted rather than left as a layer that only some code obeyed.

### 1.1 What each layer is for

**Screens** (`lib/features/**`) hold widget state and intent. They should not
know what a query looks like.

**Providers** (`lib/core/providers/`) — in practice there is exactly one,
`authProvider`. It owns the session, the profile and the role list, and the
router's `redirect` reads it. Everything else is passed down through
constructor arguments.

**Services** (`lib/core/services/`, 31 files) own the I/O. `OrderService`,
`RideService`, `CartService`, `WalletService`, `PointsService`,
`ProductLikeService`, `DocumentUploadService`, `ProviderDocGate`,
`LocationService`, `LiveMapService` and the rest.

**Supabase** is the enforcement layer. Anything the client can be trusted to
enforce is something the client is trusted not to do.

### 1.2 The resilience layer exists and is only partly used

`lib/core/resilience/` and the widgets beside it are real and tested:

| Piece | Adopted by |
|-------|-----------|
| `AppFailureMapper` | `safeCall`, `safe_realtime`, most newer services |
| `ErrorLogger` → `client_error_logs` | `bootstrap.dart` (root), asserted by `assert_resilience_is_wired()` |
| `AppErrorBoundary` | `bootstrap.dart` (root), and `user_dashboard.dart` for the shell **and each of its four tabs** |
| `ResilientFeed` (channel **and** poller together) | **nothing — see §5.1** |
| `AsyncView` (loading / error / empty, content-preserving) | `user_orders_screen`, `user_notifications_screen` — see §5.2 |

The outcome is mostly right even where the layering is wrong: a service that
throws is caught by the calling screen's `friendlyError`, so a raw exception
does not reach a user. Verified by the 2026-09-28 audit — zero direct
renderings of an exception in `lib/`.

### 1.3 Screens that call Supabase directly (the real list)

Roughly 90 files make a Supabase call; 29 reference no resilience helper at
all, and 13 of those perform writes. The write-bearing ones are
`cart_service`, `staff_gateway_service`, `payment_methods_service`,
`help_chat_screen`, `document_upload_service`, `review_service`,
`favorites_service`, `order_chat_service`, `location_service`, `ride_service`,
`error_logger`, `city_service`, `wallet_service`. Most user-facing screens
(`user_category_screen`, `user_orders_screen`, `user_notifications_screen`,
and most of the 24 admin screens) build their own queries inline.

**This is the largest structural debt in the app** and it is not a
correctness bug — it is a durability one: a future refactor has no single
place to find "every write".

---

## 2. Role / permission map

The role enum is small and is not the same as the permission system.

```dart
enum AppUserRole { user, vehicleProvider, serviceProvider, admin }
```

(`lib/core/providers/auth_provider.dart`). `_getDashboardPath` in
`app_router.dart` is the only place a role becomes a landing page: staff
gateway → `/staff/dashboard`, admin → `/admin`, vehicle → `/vehicle`, service
→ `/provider`, otherwise `/user`.

**There is no Booking Provider role.** See §5.4.

### 2.1 What each role can do

| | User | Service provider | Vehicle provider | Admin | CEO |
|---|---|---|---|---|---|
| Browse All/Booking/Vehicles/Shops tabs | ✅ | ✅ | ✅ | — | — |
| Like / dislike a product | ✅ | ✅ | ✅ | — | — |
| Cart → checkout → place an order | ✅ | ✅ | ✅ | — | — |
| Pay a provider by screenshot proof | ✅ | ✅ | ✅ | — | — |
| See a provider's phone number | **after APPROVED only** | same rule | same rule | ✅ | ✅ |
| Request a ride / track / rate | ✅ | ✅ | ✅ | — | — |
| Wallet, recharge, points, rank badge | ✅ | ✅ | ✅ | — | ✅ (read) |
| Upload a product / service | ❌ | ✅ | ❌ | — | — |
| Manage the provider gallery | ❌ | ✅ | ❌ | — | — |
| Confirm availability on an order | ❌ | ✅ | ❌ | — | — |
| Post and edit a vehicle | ❌ | ❌ | ✅ | — | — |
| Attach **images** to a vehicle | ❌ | ❌ | ✅ | — | — |
| Claim and complete a ride | ❌ | ❌ | ✅ | — | — |
| Rate the other side of a completed order | ✅ | ✅ | ✅ | — | — |
| Approve users / providers / payments | ❌ | ❌ | ❌ | ✅ | ✅ |
| Edit fees and the points rate | ❌ | ❌ | ❌ | read-only | ✅ |
| Create staff, set staff jobs | ❌ | ❌ | ❌ | ❌ | ✅ |
| View the CEO workspace | ❌ | ❌ | ❌ | ❌ | ✅ |
| Browse **all** users & providers, delete one outright | ❌ | ❌ | ❌ | ❌ | ✅ |

### 2.2 The permission system underneath

Two things that are often confused:

1. **`user_roles`** — coarse: is this account an ADMIN, a STAFF member, a
   PROVIDER, a USER. Drives `_getDashboardPath` and the router.
2. **`staff` + `staff_jobs` + `staff_warnings`** — the fine-grained system for
   people who work *for* the platform. Nine job keys (`registrations`,
   `payment_verification`, `sales_transactions`, …) describe what a staff
   member may do; `staff_has_permission()` is checked inside the RPCs, and the
   UI only ever reflects it.

**A route in `app_router.dart` is navigation, never protection.** Every
sensitive read and write re-checks server-side — `is_admin()`, `is_ceo()`,
`staff_has_permission()`, `admin_can()`. `/ceo` renders an explanation to a
non-CEO rather than the workspace, and that is a courtesy, not a control.

### 2.3 Exposure rules worth knowing

- `public_provider_profiles` is a `SECURITY_BARRIER` view granted to `anon`.
  It is the only public projection of a provider, and it deliberately carries
  city and category but **not** street address or phone.
- `provider_trust_stats` is a plain view of aggregates (rating, review count,
  completion rate, member-since) with no RLS of its own — views run with the
  owner's privileges. Deliberate, documented in migration 27.
- `staff_jobs` is session-only as of migration 83 (§5.5).
- Precise driver positions are never public: `nearby_provider_markers()`
  rounds to ~110 m and requires a session; a driver's exact location is only
  readable by a rider who has claimed a ride with them.

---

## 3. The two hard flows

### 3.1 Order → payment → contact reveal

```
user                    client                    database
 │  add to cart
 │──────────────────────────────────────────────►  cart_items (own rows only)
 │  checkout ─────────────────────────────────►  order-create  (Edge Function,
 │                                                  price is computed server-side;
 │                                                  the client cannot set it)
 │                                          ◄──  order PENDING_PROVIDER
 │                                                  requires_availability_confirmation
 │                                                  snapshotted onto the order
 │
 │  sees "waiting for the provider" — no phone, no payment details,
 │  no upload option
 │
 │                        provider (or an admin)
 │                        accept ────────────────►  order-transition (Edge Fn)
 │                                                    -> ACCEPTED
 │                        ◄── payment details AND the upload button appear
 │                            together, in one card
 │
 │  pay into the account shown, then attach the screenshot
 │  ───────────────────────────► order-transition -> PAYMENT_PENDING   (85)
 │  ───────────────────────────► payment_proofs
 │                              order-transition -> PAYMENT_VERIFICATION
 │                        sees the proof ──────────  (admin queue)
 │                        admin verifies ──────────►  order APPROVED
 │  ◄── release_order_contact(order_id) ──────────  phone number, once, audited
 │  ◄── review allowed only after COMPLETED
```

Three flags carry the gating, all `NOT NULL DEFAULT false`, so nothing that
works today changes until a provider opts in: `products.requires_availability_confirmation`
and `orders.requires_availability_confirmation` (migration 74). The order-level
copy is what the screens read, deliberately — re-joining through `order_items`
would let a provider close the payment screen on an order a buyer has already
paid for.

**The chain has to end somewhere (migration 85).** Migration 74 built the gate
but not its last link. The buyer could only submit from `PAYMENT_PENDING`, and
only the provider could move an order there from `ACCEPTED` — so a gated order
sat at `ACCEPTED` with the accounts on screen and no button anywhere, until the
provider happened to open their own list and press "Request Payment". Checkout
was already promising the buyer an upload option that did not exist yet.
Migration 85 adds one clause: on an order whose snapshot is true, **the buyer
may move `ACCEPTED -> PAYMENT_PENDING` themselves**. It is scoped to the
order's own owner and to gated orders, so an un-gated order is byte-for-byte
unchanged, and it opens only the step where a proof can be *attached* — contact
and fulfilment stay behind a VERIFIED proof. Asserted by
`assert_gated_buyer_payment_request_is_wired()`.

The payment details and the upload button are rendered in **one card**
(`_paymentStepCard`). They used to be at opposite ends of a long scroll, so
"confirmation happened" and "there is something to act on" were two separate
facts. The card is gated on the buyer's eligibility, not on the read of
`payment_methods` succeeding, so a failed read cannot remove the only way to
pay.

`release_order_contact()` is server-side and idempotent: before APPROVED it
refuses, and it writes the release to `admin_history`.

### 3.2 Ride request → match → complete

```
rider                                   driver
 │  /map  (live map, "Where to?" search)
 │  /user/ride-request
 │  GPS entry OR manual address OR map pin
 │──────────────────────────────────────────────►  create_ride_request()
 │                                          ◄──  ride_requests REQUESTED
 │
 │                                    driver online ──► set_driver_online()
 │                                    /vehicle/ride-requests  (live_map_open_rides)
 │                                    claims ──────────────►  ride-claim (Edge Fn)
 │                                                        -> CLAIMED, ride_id set
 │  /user/ride-active  ◄── realtime on ride_requests ──┐
 │                                                        │
 │                                    /vehicle/trip ─────┘
 │                                    transition_ride_status: EN_ROUTE ->
 │                                    ARRIVED -> TRIP_STARTED -> COMPLETED
 │                                    driver pushes GPS throughout
 │  ◄── fare charged on COMPLETED ───────────────────────
 │  both sides may rate (ride_ratings)
```

`ride_requests` and `driver_status` are in the `supabase_realtime`
publication with `REPLICA IDENTITY FULL` (migration 61) — without FULL, a
stream filtered on a non-key column (`status`) is rejected outright with a
CHANNEL_ERROR. That is the whole reason migration 61 exists.

---

## 4. Cross-cutting rules the code does follow

These are all load-bearing, and all of them have a test or an assertion.

**One classifier.** `AppFailureMapper` is the only place an exception becomes
a kind. Two classifiers is how one fault starts producing two different
sentences in two screens.

**Data beats "[data] wins".** A failed refresh never replaces good content
with an error.

**No unbounded queries.** Every list query has a `limit`.

**Money is never retried.** `RetryPolicy.money()` is one attempt. Duplicate
charges are worse than failed ones, and the idempotency key is the real
protection. 20 migrations reference `idempotency_key`.

**A denormalised counter is not a client write.** `products.like_count` and
`dislike_count` are maintained by `trg_product_likes_count`, which runs as the
table owner and therefore is exempt from both RLS and
`enforce_provider_write_gate` (which exempts `pg_trigger_depth() > 1`). Any
future counter on a guarded table needs this.

**A fee quoted to a human resolves exactly the way it is charged.** Migration
107 made the commission, the ride fare and the subscription fee resolvable per
category and per city. Each of the three client surfaces that *state* one of
those numbers was still reading the flat global value while the wallet was
debited with the per-category one — so the figure on screen and the figure
charged diverged the moment an admin set an override. All three are now quoted
through the same resolver the charge uses, and each keeps a fallback to the
pre-107 call for a deployment that has not run the migration yet.

Two things about that are worth stating because they are easy to get wrong
again:

  * The quote must run **after** the read that supplies the category and city.
    The first version of this fix named the right function and passed every
    other assertion, and was still wrong: the quote read two fields that were
    populated a few lines later, so both were null and the RPC inherited the
    global rate. Nothing in the code looked wrong.
  * A fee that reads a *setting* rather than calling a *resolver* is the tell.
    `system_settings.monthly_subscription_fee` is the default;
    `fee_subscription(category, city)` is the truth. Same for
    `platform_transaction_fee` versus `platform_transaction_fee_for`.

`check_quoted_fees_resolve_like_the_charge` asserts both, and its falsifier
plants each of the three surfaces, the ordering defect, and the missing
fallback.

**A provider may only work once verified, paid and funded.** Migration 0113.
A provider posts a listing, adds a vehicle, claims a ride or accepts an order
only when their identity document is **verified**, the one-time activation fee
is paid, and the wallet can cover the platform fee. All four surfaces go
through one predicate, `provider_can_fulfil()`, and the refusal names its
reasons rather than saying no.

Two defects sat behind that, and both were invisible:

  * **"Documents satisfied" did not mean verified.** `provider_docs_satisfied()`
    admits `MANUAL_REVIEW` — which is the state a document row is *born* in
    (the column defaults to it and a BEFORE INSERT trigger forces it). So the
    document half of the gate was satisfied by the act of uploading an ID,
    before any human had looked at it. The old function is untouched, because
    two assertions depend on it; the strict rule lives beside it as
    `provider_documents_verified()`.
  * **Three of the four surfaces had no gate at all.** `claim_ride` and
    `transition_order_status` never consulted one, so a vehicle provider with
    an unpaid activation fee and an unreviewed ID could take a rider's trip,
    and accept an order — while the buyer-side checkout, which *did* check,
    refused the same provider. The rule existed, was enforced in one place, and
    was simply absent from the others.

  The subscription needed no new check, and that is worth knowing: an unpaid
  monthly fee already sets `provider_profiles.status = 'SUSPENDED'` via
  `charge_due_subscriptions()`, which every one of these surfaces already
  requires to be `APPROVED`. Adding a second subscription predicate would be a
  third place for the rule to live and a third place for it to disagree.

  The CEO's control over the subscription is therefore already end to end: set
  the fee (per category and per city since 0107, plus the on/off switch), the
  scheduler bills the wallet, a short balance suspends the provider, and a
  recharge restores them. No deploy is involved in any of it.

  **Read `provider_fulfilment_gate_report()` right after deploying.** Turning
  "uploaded" into "verified" will stop any provider whose document is still
  awaiting review, which is the rule that was asked for and is also a real
  number of accounts. The report lists them with their reasons. If that is too
  many to absorb at once, the CEO can set `enforce_verified_documents` to
  false in Settings — no deploy, no migration. The other three blockers are
  not behind that switch; they were the intended rule all along.

**A notification is the only thing that makes a marketplace reactive.** The
counterparty on an event has to be told by the event. Before migration 0114,
three of the most important ones fired silently: a **provider** was never told
an order arrived, **no driver** was ever told a ride was nearby, and a **rider**
was never told their ride had been driver-assigned. `ORDER_RECEIVED` and
`RIDE_CLAIMED` have been members of the `notification_type` enum since 0001
and nothing had ever written them; fifteen of the enum's twenty-nine values
are in that position, which is the clearest evidence in the repository that
the enum was designed from the data model rather than from the flows.

All three "worked". That is why they survived: the counterparty found out by
polling, and polling raises nothing, logs nothing, and screenshots as a
working screen. `check_provider_is_told_about_work` asserts the three.

**A notification must never take down the thing it was describing.** Every
insert on those paths goes through `notify_best_effort()`, whose
function-level `EXCEPTION` clause logs and returns NULL — the same contract
`notify_user_once()` has had since 0086. Making the notification load-bearing
would mean a full notifications table takes down every purchase in the city,
which is strictly worse than the silence being fixed. The driver fan-out is
capped at the nearest 12 within 10km for the same reason: a busy city at peak
time would otherwise write one row per driver in the country for one request,
which is a denial of service against our own table.

**A value that must EXIST is not the same as a value that PARSES.** Migration
0107 wrote `insert_notification(..., 'RIDE_REQUESTED', ...)`; the enum spells it
`RIDE_REQUEST`. `insert_notification`'s second parameter is typed
`notification_type`, so the cast raised at RUN time and **every ride request in
the product failed**. Nothing caught it: `pglast` parses an enum literal as an
ordinary string and validates nothing about it, the plpgsql gate only checks
that embedded statements parse, and the existing notification assertions
compared against hand-typed needle lists. `check_notification_types_exist`
reads the enum (folding in every `ADD VALUE`) and walks the arguments of every
notification call **by position** — the type is the second argument, or the
third for `notify_user_once`, and the first argument is routinely
`(select user_id from provider_profiles ...)`, so a naive comma split reads
the wrong thing. "Parses clean" was never evidence that a value exists.

**A server refusal must arrive as a sentence, not a code.** `RAISE EXCEPTION
'INSUFFICIENT_PERMISSION'` reaches the client as a **400** whose body is the
raw code, not a 403 — so the authorisation branch of `friendlyError` never
matched it and the user saw the generic "Something went wrong". A staff member
who acted outside their assigned city was told, in effect, that the app had
crashed. `ADMIN_ONLY` and `AUTH_REQUIRED` had the same problem, found by the
same check. Asserted by
`check_server_refusal_codes_reach_the_user`.

**A reaction is a set, not a toggle.** `set_product_reaction(product, LIKE |
DISLIKE | NONE)` states intent; it does not flip what is there.

**Identity is verified after signup, and the liveness signal is a signal, not
a gate.** No ID is collected at registration — for users or providers. The
document step lives in-app, before a booking, a listing or a ride claim. When
a document row is written, `DocumentUploadService` takes one GPS fix and
records it on that row. It never blocks: GPS off or permission denied records
`UNAVAILABLE` and the upload proceeds.

**The signup OTP is a toggle, not a rule.** `signup_otp_required` (migration
82) is currently **false**, because `send-otp` has no working email provider
and the gate was taking registration down entirely. Admin approval is the gate
on a new account, and identity is checked later at the document step. Turning
the OTP back on is one `UPDATE`.

While it is off, `verify_email_otp()` completes the code screen **without
stamping `verified_at`** (migration 84). That single property is the whole
safety of the arrangement: `handle_new_user()` reads `otp_verified_recently()`,
which reads `verified_at`, so an address that skipped the code carries no
verification forward and must produce a real code the moment the OTP is
switched back on. `assert_otp_bypass_is_scoped()` fails if that ever changes —
because a bypass that records a verification is invisible in review and its
consequence is a security property quietly disappearing, not a crash.

**A scope that is not read is not a scope.** `staff.category_scope` and
`staff.city` (migrations 107–112) are the clearest example in the repo of a
rule that was fully implemented on the server and completely invisible in the
product. Both columns were writable from the CEO's terms editor, both were
enforced by predicates, and neither appeared on a staff card — so a manager
set a person to Hawassa, saw nothing confirming it, and worked whatever queue
they opened. `admin_staff_roster()` now returns rank, city, obligations and
movement counters, and `admin_staff_screen.dart` renders all four on the row
itself. The city chip says **All cities** when unscoped, because a chip that is
simply absent is indistinguishable from a chip whose city failed to load.

The rule generalises: any future scope — region, vehicle type, language — must
land in the same three places or not at all. The predicate (`staff_scope_*`),
the card that shows the assignment, and the list that filters on it. Two of
three is a column.

**One surface is one definition, and the definition names its data.** Three
surfaces in this app were each implemented more than once, and in every case
the copies drifted silently because each one was correct on its own screen:

| What | The one definition | Who renders it | What it reads |
|---|---|---|---|
| The account | `AccountDashboard` (`lib/features/user/user_profile_screen.dart`) | the buyer's Account tab, and the Account tab of **both** provider dashboards (`embedded: true`, `padding: EdgeInsets.zero`) | `authProvider` → `profiles.full_name/phone/email/status` and the role list; `PointsService.getMyPoints()` → `user_points.points` filtered by `subject_type`/`subject_id`; `RankService.progressForPoints()`; `cityProvider.updateSavedCity()` → `profiles.city`; `VerificationStatusTile` → `ProviderDocGate.reviewState` → `user_documents` |
| A category's glyph | `categoryIconForSector()` (`lib/core/utils/category_icons.dart`) | `_rankedCategoryChip` on Home and every row of `UserCategoryGroupScreen` | `categories.marketplace_sector` (FOOD / RETAIL / ACCOMMODATION / SERVICES / TRANSPORT); `Icons.category_outlined` for null or unknown, never a guess from the name |
| Which big card a category belongs to | `CategoryGroup.membersOf()` (`lib/features/user/user_category_group_screen.dart`) | the three cards on Home **and** the screen each card opens | `categories.id/parent_id` (`parent_id IS NULL`), `.sector`, `.marketplace_sector`, `.sort_order`, `.is_active` |

The `embedded` flag is the whole contract for the shared account: the buyer's
tab owns its app bar and its scroll view, and a provider dashboard's tab is
already inside one, so the dashboard renders as a plain column there. The
widget owns the account; the host owns the frame. Adding a fourth account
surface means adding a caller of `AccountDashboard`, not a fourth copy.

**A ranking that is displayed must be re-derived for the level it names.**
`ranked_categories` ranks every active category by **completed work in the
last 7 days** — completed order lines for its listings (`order_items` joined
to `orders` and `products`, read from `orders.updated_at`) plus completed
rides booked against it (`ride_requests.vehicle_category_id`,
`ride_requests.updated_at`) —
then career totals, then name and id (so the order is total). Home used to
print that list verbatim, which named the same three mother categories the
cards above it already named.
`subcategoryRailOrder()` turns the ranking plus `categories.id/parent_id` into
the leaf rail above Fresh Finds: one leaf per mother per round, in the
mothers' ranked order, because a listing is filed against the category its
provider picked (usually the mother) and every leaf's own week count is
therefore zero. The tiebreak cannot save it — it sorts by name, so a "top
this week" rail built on the leaf counts alone is alphabetical. Tested
directly in `test/home_subcategory_rail_test.dart`; the rule is invisible on
screen when it is right and looks plausible when it is wrong.

**A restated function must be a superset of the one it replaces.** Four
migrations in this session re-issued `admin_registration_history`,
`staff_task_feed`, `verify_payment_proof` and the five provider lifecycle
actions to add a city guard. Each was copied from the newest definition of that
function — not from the migration that happened to mention it first — because
the stale copy is how `approve_provider` lost its welcome notification once
already. `tools/harness/restated_body_diff.py` now proves it mechanically: a
restated body must contain every non-comment line of its predecessor, in order,
and may add only the approved guard block.

### 4.x A money notification never blocks the money

Every notification attached to a payment, a credit or an approval goes through
`notify_user_once()` (migration 86), never a bare `INSERT INTO notifications`.
That is two guarantees in one call, and both have a failure mode that is
invisible until money is involved:

* **Once.** The key is checked under `pg_advisory_xact_lock`, so a retried
  call — a double tap, a redelivery, a scheduler running twice — cannot write a
  second row. Reading the key without the lock is a race: two calls both see
  "nothing there yet" and both write.

The check has to read **both** delivery tables, and the first live run proved
it. `notify_user()` routes on `is_server_write()`: a server write inserts into
`notifications` directly, a **client write inserts into `notification_outbox`**
and does not reach `notifications` until pg_cron drains it. A dedupe that read
only `notifications` therefore missed every client-path notification — and the
connectivity suite runs as `anon`, so the client path is the normal path, not a
corner case. A retried call found nothing, queued a second row, and both
messages were delivered. Migration 92 checks both.
* **Never fatal.** The body is wrapped so any error becomes a `RAISE WARNING`
  and a NULL return. Without this, an undeliverable notice inside
  `approve_wallet_recharge` or `convert_points_to_wallet` rolls the real
  payment back and reports it as a failure — the money would be correct and the
  user told it failed.

The same discipline the wallet ledger already used for `idempotency_key`. The
key is stored in the existing `data` jsonb under `idem_key`, so no column and
no table were added.

**Where the notice is written, and why not always a trigger.** Order and ride
notices hang off the existing status triggers: an `AFTER UPDATE` trigger runs in
the same transaction as the write, so it cannot drift out of sync with it, and
restating `transition_ride_status` would mean reproducing all nine status
branches — the blast radius that once froze every ride stuck in
`DRIVER_EN_ROUTE`. Points conversion is the exception and lives in the function
body, because it moves money without updating any row a trigger covers, and the
message has to quote figures that exist only as local variables.

**Messages state what actually happened.** Ride completion does *not* add money
to the driver's wallet: it calls `deduct_transaction_fee()`, which debits the
platform commission, and the fare is settled outside the app. Order payment is
likewise made outside the app and verified from a screenshot. So the messages
quote the amount and say the commission was deducted; none of them claims a
wallet credit. `assert_order_and_ride_receipts_are_sent()` fails if that
wording comes back.

**Batching.** One ride completion produces two driver notifications by design —
one about the trip, one about the fee, the latter from `deduct_transaction_fee`
with the exact figure. They are deliberately non-overlapping rather than merged,
because the fee amount is computed inside the fee function and is not available
to the trigger. Approvals are single: the status notice and the welcome are
different messages, and both are keyed, so a retried approval adds neither.

**Every fee the platform charges is income, and every reader has to see all
three.** Income lives in `wallet_transactions.platform_fee`, written by three
paths: `deduct_transaction_fee()` (orders on `STARTED`, rides on `COMPLETED`,
type `TRANSACTION_FEE`), `deduct_subscription_fee()` and the monthly scheduler
(`SUBSCRIPTION_FEE`), and `approve_wallet_recharge()`, which withholds the
one-time `provider_registration_fee` from a provider's **first** approved
recharge and records it as `platform_fee` on a `RECHARGE` row (gross = the
amount paid, net = amount − fee; every later recharge carries
`platform_fee = 0`, so summing the column cannot double-count a deposit).

Only the first two were counted for a long time, in both the admin income
summary and the dashboard total. The result was not an error and not an empty
state but a confident **ETB 0.00** on a deployment whose providers were still
activating — and the activation fee is the only income a provider pays before
completing an order. Both readers now query all three types, and
`check_income_readers_count_every_fee_type()` fails the build if a file that
folds `platform_fee` stops naming one of them.

The related trap: the ledger assertions (`assert_recent_started_orders_have_-
fees()`, `assert_recent_completed_rides_have_fees()`,
`assert_income_ledger_consistent()`) are **existential-negative** — "no row that
exists lacks its fee row". They pass with zero rows, so a green money suite is
not evidence that any income exists. Read the counts before trusting the
number on the screen.

---

## 5. Known gaps

Ranked by how much they hurt a real user. Effort: small = an afternoon,
medium = a day or two, large = more.

### 5.1 `ResilientFeed` is adopted by no screen — **medium**
The class is `ResilientFeed` in `lib/core/services/safe_realtime.dart`; the
name `SafeRealtimeFeed` this section used to use appears nowhere in `lib/`.
It runs a channel and a poller together and emits from whichever works, which
is the correct answer for a dropped socket. Nothing uses it. What five screens
adopt instead is `ResilientSubscription`, which has no poller —
`live_map_service`, `live_map_screen`, `user_active_ride_screen`,
`driver_ride_requests_screen` and `driver_trip_screen`. And
`staff_dashboard_screen._listen()` subscribes through
`_service.subscribeToTaskFeed()` then awaits `channel.subscribe()` with
**no status callback, no reconnect and no fallback** — if that channel errors,
the one screen whose whole job is telling staff what to work on goes quiet
until someone pulls to refresh.
*Fix:* move `staff_dashboard` onto `ResilientFeed`; needs a device to verify.

### 5.2 `AsyncView` is still barely adopted — **medium**
The widget exists and is correct, and two screens use it (`user_orders_screen`,
`user_notifications_screen`). Home no longer does: it needs a first-frame
skeleton and a keep-content-on-failed-refresh strip of its own, so it
implements the same rule directly (`_buildSkeleton`, `_StaleBanner`). The rest
hand-roll `LoadErrorView` + `RetryWidget` — `LoadErrorView` is referenced by 33
files, including `async_view.dart` itself. The behaviour is mostly right, so
this is consistency, not breakage.
*Fix:* per-screen swap, mechanical.

### 5.3 Vehicles cannot have images — **fixed, migration 97**
`vehicle_images` had existed since migration 0001 with RLS and storage
policies, and **no Dart file referenced it**: `vehicle_form_screen.dart` had
no image picker at all, so a vehicle provider could post a vehicle but could
not photograph it. The database work was written but unreachable, and the
`vehicle-images` bucket was in the state `provider-gallery` had been in —
declared only by `0012`, which is below the deploy baseline and therefore
marked applied without ever being executed, so it did not exist live. The
client and the bucket were the two halves of one gap.

`0097` closes both. It creates `vehicle-images` with `ON CONFLICT DO UPDATE`
(public, 5 MB, jpeg/png/webp), restates the four storage policies (`0012`
never executed), restates the table and its owner/read policies, and revokes
`INSERT`/`UPDATE`/`DELETE` from `anon`/`authenticated` so the app writes only
through two new `SECURITY DEFINER` functions — `add_vehicle_image()` (which
refuses a path outside the caller's own `{uid}/{vehicle_id}/` folder) and
`delete_vehicle_image()` — mirroring the provider gallery's
`add_gallery_image` / `delete_gallery_image` from `0055`. The Dart side is the
consumer: `vehicle_form_screen.dart` now picks, uploads (path
`{uid}/{vehicle_id}/{stamp}-{name}`), lists and removes vehicle photos, and
the two silent early returns in its `_save()` now report their failure.

The rule that the bucket, the policy and the upload path are introduced
together is what `0096` stated when it deliberately left `vehicle-images` out.
`check_client_buckets_are_created()` fails the build if a bucket appears in
`lib/` without a migration the pipeline runs, and `assert_app_buckets_exist()`
fails the live suite if it is not there or has the wrong visibility.
`assert_bucket_writes_are_owner_scoped()` now covers all six buckets.

### 5.4 There is no Booking Provider role — **large**
`AppUserRole` has four values and none of them is a booking provider. "Booking"
exists only as a product `service_group` / category tab that determines which
order lifecycle applies. Building the role means a fifth enum value, a
dashboard, a booking-specific lifecycle and its own approval path.
*Deliberately not built — see the brief.*

### 5.5 `staff_jobs` was readable with the anon key — **fixed, migration 83**
RLS was disabled on a table whose whole purpose is to be withheld from anon
(`list_staff_jobs()` is explicitly `REVOKE`d from anon). Now RLS on, a
read-only policy for `authenticated`, `REVOKE` from anon, with
`assert_staff_jobs_are_session_only()` proving both directions.

### 5.6 Two Edge Functions were never deployed — **fixed**
`account-change-password` and `account-deletion-gateway` are called from
Flutter and were absent from `deploy-supabase.yml`, so **"Change password" and
"approve account deletion" were both calling functions that did not exist.**
Same class of bug as the `user-admin` omission recorded in that workflow.
Both deploy steps added.

### 5.7 Sponsored ads do not exist — **large**
There is no ad product anywhere in `lib/`: no table, no RPC, no screen, no
purchase path. `grep -ri 'sponsor\|advert\|promo' lib/` returns three
unrelated files. A provider cannot buy placement, so the corresponding step in
a provider walkthrough is a no-op.

Confirmed again while building the money notifications (migrations 86–89): the
"ad purchase charged" and "ad refund" notifications that were requested have no
function to attach to. There is no ad table in any migration and no ad purchase
path in `supabase/functions/`. Building them would mean inventing the feature,
not wiring a notification to it, so they are listed here as not-applicable
rather than silently skipped. The nearest real equivalent — money leaving a
wallet and coming back — is covered: a points conversion notifies with both
figures (89), and `ORDER_REFUNDED` already notifies the buyer (58).

### 5.8 Push notifications are not implemented — **medium**
`firebase_messaging` is not a dependency. Notifications are in-app only
(`notifications` table, polled/realtime). Background order and ride alerts do
not reach a locked phone, so a user who has not opened the app since a payment
cleared learns about it only on next launch. Worth knowing when reading the
money notifications in §4.x: they are written correctly and delivered, but
delivery is pull-based.
not exist. Migration groundwork (0007) is there.

### 5.9 Layering is not enforced — **large**
See §1.3. 13 write-bearing services bypass the resilience layer.

### 5.10 Category lists are capped at 100 — **small**
`visible_products_for_city` ranks by popularity and caps server-side. A
category with more than 100 products truncates silently.

---

## 6. What is asserted, and where

Correctness a reviewer cannot check by reading is asserted somewhere
executable. SQL is asserted against the **live** database by Connectivity CI
(`tools/integration_test/connectivity_test.dart`); Dart and the Edge Functions
are asserted against source by `test/` and the checks under `tools/harness/`,
run as `sh build/run_all.sh`.

That last path is a shim. `build/` is in `.gitignore` because it is the
Flutter output directory, so a harness placed there is never committed and
does not survive a clone — which is exactly how the previous set was lost in
the repository import. The real files live in `tools/harness/`, which git
tracks, and the shim exists only so the documented command keeps working.
The harnesses need no Dart SDK, no Deno and no credentials, so they run
anywhere the repository is checked out.

**The dashboard quick-action pill is one component, not three buttons.**
`QuickActionPill` (`lib/core/widgets/quick_action_pill.dart`) is the single
prominent shortcut each dashboard offers above its tabbed content: brand
green, fully rounded, icon + 13px/w700 label, sized to its content rather
than stretched. The user home screen's "Book a ride" was the original
instance and is now a call to it, so the style is defined once — the
alternative is three hand-written pills that drift into three button styles
and a redesign applied three times. The service provider dashboard shortcuts
to **My Gallery** and the vehicle provider dashboard to **Ride Requests**;
both are additive, and both tab entries remain.
`check_quick_action_shortcuts_are_wired` holds all three to it.

**OAuth accounts are gated on a verifiable profile, and the gate is
routing, not advice.** `handle_new_user()` builds `profiles` entirely from
`raw_user_meta_data`; the password flow passes `full_name`, `phone`, `city`,
`kebele` and `street_road` through `signUp(data:)` (see
`AuthNotifier.signUp`), and Google supplies none of them. An OAuth account
therefore arrives with `full_name = 'New User'` and no phone or address.

The `user_documents` INSERT is *not* what breaks — that table needs only
`user_id`, `document_type` and `storage_path`, so the upload succeeds. What
breaks is **verification**: `admin_user_management_screen.dart` renders
`phone ?? ''` as a blank line and hides the national-ID row entirely when it
is null, so the reviewer is handed a document with no identity to check it
against. The account is unverifiable, not blocked — which is why it went
unreported.

`UserProfile.isVerifiable` is therefore true only when the name is neither
empty nor the trigger's `'New User'` placeholder, and phone, kebele and
street_road are all present. `national_id` is deliberately **not** required:
no sign-up collects it, it is proven by the uploaded document, and demanding
it would bounce every user to a form the app cannot check.

The router sends anyone failing that test to `/complete-profile`, which saves
through the `complete_profile()` RPC (SECURITY DEFINER, self-scoped — the
`profiles` owner UPDATE policy is 0014-only and the 20260927000050 write
closure leaves no grant to rely on). Admins and staff gateway accounts are
exempt; they are created by the app and are not verified against a national
ID. The gate runs on *every* navigation, so it cannot be bypassed, and
`/complete-profile` is registered in `_isApprovalRoute` — without that, an
OAuth account (which is `PENDING_APPROVAL`) is bounced off the form by the
pending gate and sent straight back, forever.

`/complete-profile` is deliberately **not** in `isAuthRoute`: that branch
redirects away to the dashboard, which would ping-pong with the completeness
gate.

There is deliberately **no booking-provider dashboard**: `app_role` is
exactly `(USER, VEHICLE_PROVIDER, SERVICE_PROVIDER, ADMIN)` and
`provider_profiles.provider_type` is constrained to the two provider values.
`BOOKING_BASED` exists, but as a *category* `service_group` on the shopper
side (`lib/core/models/category_tabs.dart`), not a provider account type — a
booking-provider shortcut would point at a screen no account can reach. The
check fails if one is added.

**Restatements are diffed, not eyeballed.** Two tools back the restatements in
§4.x, because this repo has twice lost a condition from a function that was
re-emitted from memory (the `provider_profiles` trigger, the `staff_task_feed`
RPC):

* `python3 tools/harness/restatement_diff.py <migration> <fn>…` compares a
  restated body against the previous definition statement by statement. It
  separates *lost* from *rewritten*: a branch only counts as rewritten if the
  new body still notifies on that same status, and every rewrite must be
  declared in `REVIEWED_REWRITES`. An undeclared rewrite fails.
* `python3 tools/harness/fault_inject_notifications.py` reintroduces 25 real
  bugs — a dropped dedupe check, a dedupe that reads only one delivery table,
  a missing lock, a removed error handler, an unrevoked privilege, a lost
  authorization clause, a false "money added" claim, an assertion the CI
  client cannot reach, a mistyped source needle, a plpgsql loop that cannot
  run — and requires the harness to go red for each. A check that passes on
  broken input is worse than no check, because it is reported as a safety net
  while providing none.

  It found **thirteen** vacuous or wrong checks across five rounds. The
  recurring cause was matching on text that was not the thing being checked: a
  substring of the whole migration that also appears in that migration's own
  assertion; a comment inside a function body keeping a deleted `EXISTS`
  alive; a needle sensitive to the author's line wrapping; a needle with a
  typo; and a privilege model that ignored statement order.

  A fourteenth and fifteenth turned up in the gallery review, both the same
  shape. The downscale check matched `pickImage(source: ImageSource.gallery`,
  and `pickMultiImage` takes no `source:` argument — so the three multi-image
  pickers (provider gallery, product form, vehicle form) were never inspected
  by a check that had read green for its whole life. And the new
  `check_provider_gallery_is_wired` passed with the dashboard tile disabled by
  `if (false)`, because the dead tile still contained the route string. Both
  are now caught: the picker regex matches both spellings, and the gallery
  check rejects any constant-false guard in the dashboard. **A check that has
  never been seen red is not yet a check.**

  Two more of the same family turned up adding the role quick-action
  shortcuts. The drift detector first scanned all of `lib/` and flagged the
  category chip in the user home tab rail — a legitimate component that merely
  shares the brand green and the 20px radius — so it is now scoped to the
  three role screens that own a shortcut. And the first version asserted the
  pill's target with a file-level search, which the *tab entry the pill
  duplicates* satisfied: pointed at `/vehicle/vehicles`, the pill check read
  green. (`check_routes_resolve` still caught that one, so nothing shipped
  broken — but a check that cannot see its own subject is the pattern this
  file exists to end.) It now reads the route out of the pill's own call.

  And a sixteenth, the worst of the set, in the gallery: the downscale check,
  the bucket assertions and three separate sessions all inspected
  `storage.objects` and the write RPCs. Nobody had ever looked at the
  `provider_gallery` **table's** read policies, which exist only in 0014 —
  pre-baseline, marked applied without executing. The upload path is
  `SECURITY DEFINER` and therefore immune to that, so uploads succeeded, rows
  were written, and the screen's own `SELECT` returned nothing. The reported
  symptom was always the write; the fault was always the read.
  `check_gallery_read_path_is_migrated` now requires the read policies to be
  created *at or after the baseline*, and
  `gallery_read_surface_report()` prints the live inventory every run so the
  next session starts from evidence rather than from a hunch.

  Falsifying that last check also caught a bug in the check itself:
  `int(migration.split("_")[0])` raises on `0022a`, a real migration prefix.
  The `ValueError` escaped `main()` and aborted the **whole** harness, so
  every other check's result was lost too. It now uses the same `isdigit`
  guard as `_current_migrations`, and the lesson generalises: a check that
  crashes the suite is worse than one that fails, because it hides the
  results of the twenty-four checks that would have told you what to fix.

  Then `0104` deployed and failed, and the cause was the deepest version of
  this pattern yet. `pglast` is libpg_query — the real PostgreSQL grammar —
  but on a `CREATE FUNCTION ... AS $$ ... $$` body it parses *plpgsql*, and
  plpgsql defers every embedded statement to execution time. So
  `string_agg(p policyname, ...)` — a space where the dot belonged — passed
  `pglast.parse_sql()` on the whole file and was rejected by the server:
  `syntax error at or near "policyname" (SQLSTATE 42601)`. "Parses clean" was
  never evidence about function bodies.

  `tools/harness/plpgsql_body_syntax.py` closes that gap: it splits each
  dollar-quoted body and parses every embedded statement as plain SQL, and
  `sh build/run_all.sh` runs it over every migration a deploy would apply
  (§7.1.1) — not the whole history, which trips its splitter on control
  flow sharing a `;` boundary, and failing the build on live, working SQL
  teaches everyone to ignore it. It took four attempts to get right, each
  caught by falsifying it against the real typo:

  * it matched `$$ … $$` with a backreference to an *optional* tag, which
    cannot match when the tag is absent — so it found **zero** bodies and
    reported success on all 200 migrations
  * its statement splitter was a nested-quantifier regex that backtracked
    exponentially and hung past a 120s timeout
  * it skipped `SELECT … INTO`, which is the exact shape it exists to check
  * it stripped `INTO` unconditionally, eating the `INTO` of `INSERT INTO` and
    inventing 500-odd false positives

  It now has a vacuity guard that fails if it finds no plpgsql body at all,
  because a check that inspects nothing and says "ok" is a green light for the
  failure it was written to prevent.

  Two more, both found by simulation rather than by reading — and both were
  **redirect loops**, the only failure class in this project that no
  source-level check could see, because a loop is a property of two branches
  *in combination* and each branch is individually correct:

  * `/ => /complete-profile => /user => /complete-profile`. The completeness
    gate sent any non-admin with an incomplete profile to the completion
    screen; `/complete-profile` was an approval route, so the "approval
    resolved" branch — which forwards anything not pending and not rejected
    to its dashboard — sent them straight back out. Any **approved** account
    predating `kebele`/`street_road` satisfied both at once, and go_router
    gave up with Page Not Found.
  * `/suspended => /provider => /suspended`, found by the same tool before
    the first was even fixed. The looser condition also matched SUSPENDED and
    INACTIVE, and the revenue scheduler creates that state on its own when a
    subscription fee cannot be paid.

  Both have the same root: "approval resolved" was written as *not pending and
  not rejected* when it means *approved*. `redirect_cycle_simulation.py`
  enumerates every (location, status, verifiability, role) combination and
  follows the redirect to a fixed point — 1,440 of them, all settling. It is
  the only check here that would have found either bug, and
  `check_router_matches_the_cycle_simulation` keeps the Dart and the model
  from drifting apart, since a simulation that has stopped mirroring the app
  is a green light for a crash.

  And the first thing it found was a check that was wrong, not a bug: 0104's
  `assert_profile_completion_is_wired()` compared `pg_proc.proargnames`
  against `'full_name,phone,city,kebele,street_road'`, but the catalog
  renders it `{p_full_name,p_phone,p_city,p_kebele,p_street_road}` — braces
  and the `p_` prefix the parameters are actually declared with. The
  assertion could never be true, so it failed against a perfectly correct
  `complete_profile()`.

  The same round, on the plpgsql gate, found a hole of the opposite kind.
  `tools/harness/plpgsql_body_syntax.py` decided which dollar-quoted bodies
  to examine by looking for `LANGUAGE plpgsql` in the 800 characters before
  the opening delimiter. A `DO $$ … $$` block is never preceded by that
  string, so **every `DO` block was skipped** — and `DO` blocks are where
  this repo puts all of its conditional DDL: 0104's gallery read policies,
  0096's bucket, 0106's column and its view rebuild. The gate had been
  reporting "ok" on all of them without parsing a single statement. It was
  found by planting an invalid `ALTER TABLE` inside a `DO` block and getting
  green back, and the first attempt to reproduce it was itself wrong: the
  mutation `ADD COLUMN c text <word>` is *valid* Postgres, which reads the
  trailing word as a constraint name. Both facts are the reason the rule
  stands — a check is only real once it has been seen to go red, and a
  reproduction has to be checked before it is believed.

  Two more holes of the same shape were found in the release pass over 016 and
  017, both of them in the *classifier* rather than in the SQL. `is_plpgsql_body`
  tested `"LANGUAGE plpgsql" in prefix` — a case-sensitive substring, while
  `SQL_BODY`, `DO_OPENER` and every other predicate in the file are
  `re.IGNORECASE`. Every migration in this repo writes `language plpgsql` in
  lower case, so a function body with no `LANGUAGE sql` anywhere near it was
  classified as *not a body*: 016 (four raw bodies) and 017 (two) were dropped
  whole, and the `found 0 bodies` guard is the only reason it surfaced. The
  second is the order in which the block opener is removed: `BEGIN` and a
  leading comment can each precede the other, and the one-shot
  `LEADING_COMMENTS.sub("", PLPGSQL_BEGIN.sub("", raw))` handled `BEGIN -- c`
  but not `-- c BEGIN`, leaving `BEGIN insert into …` glued together. That is
  not SQL, so it reported a syntax error in bodies the live database has been
  running for weeks — 85 of the 99 findings across the history. Both are fixed
  by making the predicate case-insensitive, by stripping both until neither
  applies, and by counting the delimiters in `check_file` from the text itself
  so a regression in `find_bodies` still trips the guard. `--all` now reports
  269 files clean instead of 99 failures, and `--pending` reads the two
  migrations it used to skip.

  ## Six checks that were wrong before they were ever run

  The rule above is only half of it. A check written to be correct is still
  wrong until the version *before* the fix is fed to it. Session 107–112 added
  four checks and two harnesses, and falsifying them found **six defects in
  the checks themselves** — none of which were bugs in the product, and all of
  which would have shipped a green light over a red build:

  * the sidebar-guard regex counted the `Widget _menuCard(...)` *declaration* as
    a guarded call site, so a card with no `if` around it still passed;
  * the "fee columns must be nullable" check matched `^\s*col\s+numeric`, which
    stopped at the word `numeric` and therefore never saw the `NOT NULL` two
    tokens later;
  * the staff check tested `"/admin/staff" in dashboard`, which `/admin/staff-assignment`
    satisfies — the wrong card was passing for the right one;
  * that check then counted **its own assertion functions** as evidence of
    enforcement, because their bodies contain the predicate name inside a
    `LIKE` pattern that appears *after* a `WHERE`;
  * the roster check read `s['city']` off the raw `staff` row and called that
    reading the roster, so a client that fetched `admin_staff_roster()` and
    discarded it passed every assertion;
  * and the assertion-pinning check tested "does the guard name appear in the
    body", which stays true when the test that actually uses it is deleted —
    because the same function counts occurrences for the *feed* half;
  * and the account-deletion page check required every split table to be
    declared conditional, which `docs/delete-account.html` satisfied for six of
    the eight the foreign keys actually split — `provider_payment_methods` and
    `payment_approval_screenshots` were missing from a page Google Play reads
    as policy, and `provider_payment_methods` was absent from it entirely while
    the app reads it on every provider screen. The page now states both, and
    says for each whether the account is the provider it hangs off.

  Each was found by planting the original defect, and each fix is now pinned
  by a case in `tools/harness/falsify_*.py`. The last one is the reason
  `assert_staff_city_scope_covers_the_task_feed` is required to contain a
  `position('staff_scope_allows_city' in v_proof)` call specifically, rather
  than merely the word.

  One of the six was a check that punished an honest **refactor**: renaming
  the roster map turned it red, because the check searched for the literal
  substring `roster` in the accessor name. It now discovers the accessor from
  what it does — the function that returns the declared map — so a rename
  passes and a real removal still fails. A check that fails on good work gets
  disabled, and a disabled check catches nothing.

  ## A check that had never run, and three fees that quietly diverged

  Two findings from the 0107–0112 session, both invisible to every check that
  existed at the time.

  **An assertion in an unreachable branch.** The quick-action check carried a
  rule — "the gallery pill must interpolate the provider id, or it shows
  whichever provider happens to be first" — sitting inside an
  `if not QuickActionPill(` block that an earlier `continue` had already made
  unreachable. It had never executed once. It was found while rewriting the
  same check for a different reason, and its first appearance in a falsifier
  (case D) is what proved the rewrite actually reconnected it.

  **Three fees quoted one way and charged another.** 0107 made the commission,
  the ride fare and the subscription fee per-category and per-city. The
  checkout quoted `platform_transaction_fee(amount)` — the global rate — while
  `deduct_transaction_fee()` charged `platform_transaction_fee_for()` with the
  provider's category and city. The ride screen called the five-argument
  `calculate_fare_estimate()`, which hardcodes `p_city` to NULL, while
  `create_ride_request()` charges against the rider's `profiles.city`. The
  subscription screen stated `system_settings.monthly_subscription_fee` while
  `deduct_subscription_fee()` charges `fee_subscription(category, city)`.

  The checkout one was hidden by a comment that read:

  > Display only — the charge itself is made server-side by
  > `deduct_transaction_fee()`, which calls that same function, so this figure
  > cannot drift from what the provider is actually charged.

  Every part of that was true when written and false after 0107. It is the
  clearest argument in the repo for dating comments that make a claim about
  another file: the claim outlived the fact, and a reviewer reading it would
  have skipped the call entirely.

  The pattern across all three: a screen that states a number sourced from a
  **setting**, while the server charges it from a **resolver**. Settings are
  defaults; resolvers are truth. That distinction is now an assertion.

  ## The admin "Delete user" button that could never work

  Reported as "the delete button does nothing", in both the admin and the CEO
  interfaces. They are not the same code, and only one of them was broken.

  The **CEO** path is `admin_account_directory_screen.dart` → the
  `ceo_delete_user_account` RPC → the shared `delete_user_account()` cascade.
  It asks for a reason, then a typed `DELETE`, translates every refusal code
  into a sentence, and it works.

  The **admin** path is `admin_staff_assignment_screen.dart` → the
  `user-admin` Edge Function, `action: 'delete_user'`. The function requires

  ```ts
  if ((body.confirm ?? "").trim() !== targetId) {
    return json({ error: "confirmation_required" }, 400);
  }
  ```

  — a deliberate second factor of intent, so a mis-wired button or a stale
  screen cannot destroy the wrong account. The client sent `{action, user_id}`
  and **never sent `confirm`**. The string `confirm` appeared nowhere in
  `lib/`. Every press returned 400 `confirmation_required`, so the button had
  never once succeeded.

  The three hypotheses worth naming, because two of them were wrong:

  - **A swallowed exception** — no. There is a `catch`, and it shows
    `friendlyError`. The non-2xx branch also ran; it just printed the raw code,
    `Delete failed: confirmation_required`, which reads to an admin as broken.
  - **A missing RLS DELETE policy** — no, and it could not be. Neither path
    deletes a table row as a client: both run as `service_role` (the Edge
    Function's own key, and the RPC's `SECURITY DEFINER`), so RLS on
    `profiles` is bypassed entirely. There is no `DELETE` policy on
    `profiles` and there does not need to be one.
  - **A blocking foreign key** — this was a *real* bug, and it is fixed, but
    it was not what the button was hitting. Migration `00054`'s own header
    says "deleting auth.users today fails for almost any real account": eight
    columns (`orders.user_id`, `reviews.user_id`, `ride_requests.user_id`,
    `support_tickets.user_id`, `payment_agreements.user_id`,
    `ride_ratings.rater_id`, `admin_actions.admin_id`,
    `admin_wallet_actions.admin_id`) were `NOT NULL` with no action, and are
    now `ON DELETE SET NULL` so the record survives and the link does not.
    `00054` is above the baseline, so it ran. Had the client been fixed first
    and only, the button would have gone from *always 400* to *mostly 500*.

  What is left is the smallest possible fix: send the field the function asks
  for, and translate its refusal codes. The two paths remain deliberately
  separate — the admin cannot call the CEO-only RPC, and the Edge Function
  audits into `admin_actions` while the CEO cascade audits into `audit_logs`.

  `check_edge_function_required_fields_are_sent` now guards it. An Edge
  Function's request contract lives in TypeScript and the caller's lives in
  Dart, and nothing in either language checked the other. It is scoped to
  fields that appear in a guard which *rejects* the request, not every
  `body.X` a function reads — `user-admin` also reads `body.reason` for a
  different action, and demanding that on every call would be a false
  positive that teaches everyone to ignore the check. It fails if it finds no
  guard at all, for the same reason the plpgsql gate does.

  Worth keeping for what it is. Every other fake pass in this repo's history
  went the other way — a needle satisfied by a doc comment, a check matching
  zero things, an assertion green on a table it never opened. **A check that
  is too strict is a nuisance; a check that is too lenient is what costs
  days.** This one caught itself. Migration 0105 compares against the array
  the catalog really produces, and additionally proves the RPC writes only
  its caller's own row.

**The pattern across five live rounds is worth stating plainly:** of the ten
failures, **one** was a defect in the notifications and **nine** were defects
in the assertions written to check them. Two of those would have "passed" only
by deleting a working feature. `assert_source_needles_match()` exists because
of that: an assertion whose needle does not match its target cannot be caught
by anything else, since it is the thing doing the checking.

**A plpgsql body is not validated by `CREATE FUNCTION`.** A function with a
body that cannot run deploys cleanly and then raises on every call — which for
an assertion means it silently stops asserting while still reporting as a
safety net. Migration 93 shipped exactly that (`FOREACH` over a 2-D array is
refused at run time, 42804) and only Connectivity CI calling it found out:
`db push` succeeded, and the privilege check passed because the function
existed and was executable. Migration 94 replaced the loop and it then
iterated **zero** times, which the `v_checked` counter caught as a red build
rather than a green one.

That third outcome is the general rule: **a check that examines nothing and
returns success is indistinguishable, in CI, from a check that examined
everything and found nothing wrong.** Only an explicit "did I actually look at
anything" counter separates them, and every assertion in this series has one
now. The 2-D array was removed entirely rather than re-looped — it cost two
deploy cycles — and the harness rejects array-typed `FOREACH` variables
statically, scoped to the current definition of each function.

All SQL is parsed with `pglast` (libpg_query, the real PostgreSQL parser)
before commit rather than read by eye. Two pre-existing files fail to parse and
are known: `0021_live_schema_snapshot.sql` (a `CREATE POLICY` name containing
spaces, unquoted) and `0022c_functions.sql` (`SECURITY_DEFINER` written with
an underscore). Both are historical and already applied; they are recorded here
rather than fixed, because editing a migration that has already run changes
nothing and rewriting a 2000-line snapshot is its own risk.

| Property | Where it is pinned |
|----------|-------------------|
| Every fee follows `system_settings`, in whichever direction its switch points | `assert_fees_are_data_driven()` (migration 62, switch-aware since 73) |
| Every fee switch actually switches | `assert_fee_switches_are_wired()` (migration 73) |
| Payment gated on availability; contact on verified payment | `assert_availability_gate_is_wired()` (migration 74/75) |
| A confirmed availability can actually be paid, by the buyer who placed it | `assert_gated_buyer_payment_request_is_wired()` (migration 85) |
| A like persists; a dislike replaces it; the RLS bites | `assert_likes_persist_and_are_exclusive()` (migration 76, a **write** test) |
| The provider write gate is scoped, not opened | `assert_provider_write_gate_allows_counter_updates()` (migration 76) |
| Live map is actually live (publication + FULL replica identity + marker feed) | `assert_live_map_is_wired()` (migration 61) |
| Document submission records a location, and the trigger does not overwrite it | `assert_document_liveness_is_recorded()` (migrations 80/81) |
| The signup OTP is a working toggle in either position | `assert_signup_otp_toggle_is_consistent()` (migration 82) |
| The staff-job catalogue is session-only | `assert_staff_jobs_are_session_only()` (migration 83) |
| A money notification is delivered once, and a failed one never rolls back the payment | `assert_notify_user_once_is_idempotent()` (migration 86, a **write** test) |
| Every approval path welcomes, and no restatement lost its guards | `assert_approval_welcome_covers_all_paths()` (migration 87) |
| Both parties are told an order payment and a ride completion, with the amount | `assert_order_and_ride_receipts_are_sent()` (migration 88) |
| Points→birr says so, and the money invariants survived the restatement | `assert_points_conversion_notifies()` (migration 89) |
| The notifications inbox is owner-scoped and still guarded | `assert_notification_inbox_is_owner_only()` (migration 90) |
| Every assertion the suite calls is reachable by the role the suite runs as | `assert_every_assertion_is_reachable()` (migration 91) |
| Source-matching assertions compare against text that exists | `assert_source_needles_match()` (migration 93) |
| Every storage bucket the client uses exists, and is as visible as the app expects | `assert_app_buckets_exist()` (migrations 96/97, six buckets) |
| The activation fee is withheld as income, and a second recharge withholds nothing | `assert_activation_fee_writes_income()` (migration 98, a **write** test) |
| The income report counts every fee type, and says what it measured | `assert_income_covers_every_fee_type()` (migration 98) |
| An `OTHER` document keeps its label, the constraints hold, and the insert path is intact | `assert_other_document_type_is_wired()` (migration 99) |
| A payment screenshot bucket accepts JPEG, keeps the size the client quotes, and stays private | `assert_payment_screenshot_uploads_are_accepted()` (migration 101) |
| Every bucket the app uploads to has at least one write and one read policy, counted only from policies naming that bucket | `assert_client_buckets_have_write_and_read_policies()` (migration 102) |
| A provider can read their own wallet and insert + read their own recharge requests, with RLS on | `assert_owner_can_read_and_write_their_money()` (migration 102) |
| A provider can set a shop photo, the bucket takes it, and the public view still reads | `assert_provider_photo_surface_is_wired()` (migration 106), reported by `provider_photo_surface_report()` |
| The registration queue separates staff from persons, and still does with a city applied | `assert_registration_history_separates_staff()` (107/108), `assert_staff_separation_survives_city_scope()` (110) |
| A staff city stops something on the five provider lifecycle actions, not just the queue | `assert_admin_rpc_service_role_access()` (111) — it now pins `staff_scope_allows_city` and `my_staff_scope_summary()` |
| The staff work queue carries as many city scopes as category scopes, and money verification is city-scoped too | `assert_staff_city_scope_covers_the_task_feed()` (112) — it counts both, and searches `verify_payment_proof`'s body for the guard |
| Every provider lifecycle action that carries the category guard carries the city guard | `check_staff_management_is_reachable()` + `restated_body_diff.py` (suppresses a restatement from a stale copy) |
| A restatement that REPAIRS a defect changes only the broken lines, and the repair is in the body | `restated_body_diff.py` `FIXES` (§7.1.2) — the mirror of the superset rule, which 0116 could not satisfy |
| A provider who cannot publish is told WHY, and where to fix it — before they type anything | `check_publish_refusal_is_actionable()` + migration 0117, `ProviderReadiness`, `PublishReadinessBanner` |
| A column a query references exists in the scope that query actually has | `column_scope.py` over the pending window — the 42703 class that killed two deploys and that no parser can see |
| A per-category / per-city fee inherits correctly, and a client cannot write the table | `assert_category_fees_are_wired()` (107), reported by `category_fee_surface_report()` |  | A staff member's rank, city, obligations and movement are on the screen, not only in the table | `check_staff_roster_is_wired()` — it fails if the roster is fetched and discarded, and passes on a rename |
| A provider may only work once verified, paid and funded — on all four surfaces | `assert_provider_fulfilment_gate_is_wired()` (0113), plus `check_provider_fulfilment_gate_is_wired()`; blast radius from `provider_fulfilment_gate_report()` |
| Every notification type written actually exists in the enum | `check_notification_types_exist()` — the bug that made every ride request fail, which no parser can see |
| The other side of an order or a ride is told, not left to poll | `assert_counterparties_are_notified()` (0114) + `check_provider_is_told_about_work()` |
| Every fee shown to a human is resolved the way it is charged, and degrades safely on a pre-107 deployment | `check_quoted_fees_resolve_like_the_charge()` — covers checkout, ride fare and subscription, including the ordering defect |
| A staff member blocked by a scope rule is told it is a scope rule, not a crash | `check_server_refusal_codes_reach_the_user()` — `INSUFFICIENT_PERMISSION`, `ADMIN_ONLY`, `AUTH_REQUIRED` must sit in a matcher list, not merely appear in the file |
| Every role's shortcut pill is labelled, tappable, and points at a real route | `check_quick_action_shortcuts_are_wired()` — a second legitimate pill passes; an unlabelled or hand-rolled one does not |
| The CEO delete is CEO-gated, the service-role-only cascade is unchanged, and the wrapper calls it | `assert_ceo_delete_is_wired()` (migration 100) |
| The signup gate keys off `verified_at`, not attempt arithmetic | `assert_otp_gate_uses_verified_at()` (migration 02) |
| The signup trigger's insert-time trust rules hold | `assert_handle_new_user_contract()` (migration 82, path B is toggle-aware) |
| Error sink, RLS and hot-path indexes exist | `assert_resilience_is_wired()` (migration 64) |
| Wallet balances equal the ledger | `assert_income_ledger_consistent()` |
| Approved recharges actually credited | `assert_recent_approved_recharges_credited()` |
| Ride and order fees charged on the right transition | `assert_recent_started_orders_have_fees()`, `assert_recent_completed_rides_have_fees()` |
| Subscription fee is actually scheduled | `assert_subscription_scheduler_scheduled()` |
| The optimistic like count is right, including like↔dislike | `test/product_reaction_count_test.dart` |
| Category → tab mapping against real seed rows | `test/category_tabs_test.dart` |
| Retry / backoff / jitter maths | `test/retry_backoff_test.dart` |
| Exception classification and non-leakage | `test/failure_mapper_test.dart` |
| A failed realtime subscribe cannot crash | `test/realtime_resilient_subscription_test.dart` |
| Pre-auth endpoints are deployed reachable (`--no-verify-jwt`) | `check_edge_functions_deployed()` + `PRE_AUTH_FUNCTIONS` |
| A gated order is payable after confirmation, details and upload in one card | `check_availability_payment_flow()` |
| The login screen reports its own outcome instead of spinning forever | `check_login_reports_its_own_outcome()` |
| A bucket the client writes to is created by a migration the deploy workflow actually *executes* | `check_client_buckets_are_created()` |
| Every income figure counts every fee type, the activation fee included | `check_income_readers_count_every_fee_type()` |
| The activation fee is written where an income reader can see it | `check_activation_fee_is_recorded_as_income()` |
| The account-deletion page Google Play loads is public, reachable, and says what the foreign keys actually do | `check_account_deletion_page_is_public_and_true()` |
| No foreign key refuses `DELETE FROM auth.users`, on the account side or the business side | `check_account_deletion_is_unblocked()` |

Two lessons worth keeping, both paid for:

- **An assertion that only reports `null` is not an assertion.** Migration 66
  lost three deploy cycles to `Expected: not null, Actual: <null>` from an RPC
  whose cache was stale rather than whose logic was wrong. The resilience and
  liveness tests now use `rpcTextDiagnosed`, which prints the actual error.
- **A test must not flatter the code it tests.** Migration 44's probe set
  fixtures that were more generous than production (a confirmed email the
  trigger cannot see at insert time) and reported success for two live paths
  that were in fact broken. The same failure has a source-level shape: the
  harness helper that reads a Dart method body took the first `{` after the
  signature, which for `Future<void> signIn({required String email, ...})` is
  the **parameter list**, so a check written against the body silently
  inspected the wrong text and passed. Every new check was verified by
  reintroducing its bug and confirming it goes red — a check that has never
  failed is not evidence of anything.

---

## 7. Deployment checklist

Verify a deploy against this list rather than assuming. "The workflow went
green" does not mean the app works.

### 7.1 Migrations

Applied through `Deploy Supabase` (`supabase db push --include-all`) or, when
GitHub Actions cannot run, the Supabase SQL Editor.

| Migration | Brings | If missing |
|-----------|--------|------------|
| `0001`–`0043` | core schema, RLS, storage, escrows | nothing works |
| `0044` / `20260925150000` | `handle_new_user()` with insert-time trust rules | signup rejected or trust rules inert |
| `0074` | availability-confirmation gate | payment visible before confirmation |
| `0085` | a gated buyer may open the payment step after confirmation | a confirmed order sits at ACCEPTED with payment details and no way to pay |
| `0076` | likes persist, dislikes replace | a like fills and empties silently |
| `0080` | GPS liveness columns on `user_documents` | **document upload fails** — the client inserts them |
| `0081` | fixed liveness assertion | Connectivity CI red (test only) |
| `0082` | `signup_otp_required` toggle | registration fails with "Database error saving new user" |
| `0083` | `staff_jobs` RLS | the job catalogue is readable with the anon key |
| `0084` | OTP bypass that records no verification | a build in circulation cannot pass the code screen |
| `0086` | `notify_user_once()`: keyed + failure-isolated notification call site | a retried payment notifies twice; an undeliverable notice rolls the payment back |
| `0087` | a welcome on every path that approves an account | accounts are approved and told only that a status changed |
| `0088` | both parties notified on an order payment and a completed ride, with the amount | the provider is never told a payment cleared; the rider is told nothing about the fare |
| `0089` | points→wallet conversion notifies with both figures | points convert to birr silently |
| `0090` | the notifications inbox is still owner-scoped (assertion) | a new definer function could widen who reads the inbox |
| `0091` | the new assertions are executable by `anon` | Connectivity CI cannot call them; PostgREST reports PGRST202, which reads like a missing migration |
| `0092` | the dedupe covers the client-path queue, and two wrong assertions corrected | a retried payment queues the same message twice |
| `0093` | two more assertion needles corrected, and needles are declared + verified | an assertion searches for text that is not there and reports phantom defects |
| `0094` | `assert_source_needles_match()` can actually run (subscripted FOR) | it raises 42804 on every call, so it silently asserts nothing |
| `0095` | the needle table is two flat arrays walked by `unnest(a, b)` | the second dimension cost two deploy cycles: a refused `FOREACH`, then an empty loop |
| `0096` | the five buckets the app then used are declared by a migration the pipeline runs, plus the `provider-gallery` policies `0017` never created | **the provider gallery cannot upload at all** — `provider-gallery` was created only by `0017`, which the workflow marks applied without executing it, so every upload failed with "Bucket not found" (404) and the screen could only show its generic error |
| `0097` | the `vehicle-images` bucket, its policies and table restated, and `add_vehicle_image()` / `delete_vehicle_image()` for the new vehicle-photo client | **a vehicle cannot have a photograph** — the bucket was created only by `0012` (marked applied, never executed), so every vehicle-photo upload 404s; and nothing in `lib/` could write `vehicle_images` at all |
| `0098` | `assert_activation_fee_writes_income()` (write test) and `assert_income_covers_every_fee_type()`, which report the fee figures instead of the vacuous existential negatives | the activation fee keeps being collected with nothing that proves it reaches the ledger, and the money assertions stay green on an empty wallet table |
| `0099` | `other_document_label` + a `document_type` CHECK carrying every value the app has ever written, and the pairing constraint that requires a label exactly when the type is `OTHER` | an `OTHER` upload is refused by the insert (`column "other_document_label" does not exist`), and nothing records which document the person actually uploaded |
| `0100` | `is_ceo_authority()`, `ceo_account_directory()`, `ceo_delete_user_account()` — the wrapper that records the reason in `admin_actions` and then CALLS `delete_user_account()` | the CEO directory and its delete button do not exist (`function … in the schema cache`); `delete_user_account` itself is untouched, and it stays service-role-only |
| `0101` | `assert_payment_screenshot_uploads_are_accepted()` — the two payment-proof buckets stay private, keep accepting JPEG and are not lowered below the limit the app quotes | a payment screenshot upload fails with a bucket error the client cannot explain, or a proof bucket is left public |
| `0102` | the `user-documents` / `payment-proofs` `storage.objects` policies and the `wallets` / `wallet_recharge_requests` owner policies, restated after the baseline; plus `assert_client_buckets_have_write_and_read_policies()` and `assert_owner_can_read_and_write_their_money()` | **a document upload is refused by storage and a recharge reports "That item could not be found"** — both policies existed only in `0012`/`0009`/`0021`/`0022`, which the workflow marks applied without executing, so the only policies that reached production on those tables were `00042`'s UPDATE-only pair and `20260922000010`'s staff-scoped reads, which no provider can satisfy |

| `0104` | the `provider_gallery` owner + public **read** policies, restated after the baseline; `complete_profile()` for OAuth accounts; `gallery_read_surface_report()` (a report, not an assertion) and `assert_provider_can_read_their_own_gallery()` / `assert_profile_completion_is_wired()` | **the gallery upload succeeds and the gallery is always empty.** `provider_gallery_owner_read` is defined only in `0014`/`0021`/`0022`, which the workflow marks applied without executing. The write path is `SECURITY DEFINER`, so it bypassed both the `20260927000050` revoke and any missing RLS — the upload worked, the row was written, and the screen's own `SELECT` returned zero rows. Every prior gallery report blamed a write, because every prior check inspected `storage.objects` and never the table the rows live in |
| `0105` | corrects 0104's signature assertion, which compared `proargnames` to an unprefixed rendering and so failed on a correct function; now also proves `complete_profile()` writes only its caller's own row | a false red that would have trained everyone to ignore the assertion |
| `0106` | `provider_profiles.photo_storage_path` (nullable), the public `provider-photos` bucket with four owner-scoped/public `storage.objects` policies, and `public_provider_profiles` rebuilt inside one `DO` block as a verbatim copy of `20260924000006`'s column list **plus** that one column; plus `provider_photo_surface_report()` and `assert_provider_photo_surface_is_wired()` | **every provider's public page is a flat gradient and the business profile screen has no way to change that** — `provider_profiles` had no photo column, no bucket existed, and the only photo-bearing table in the schema (`provider_stores.logo_storage_path`) is declared only in pre-baseline `0013`–`0022d`, which the workflow marks applied without executing, and which no file in `lib/` references |
| `0107` | `category_fee_settings` (every money column nullable, NULL = inherit, `UNIQUE(category_id, city)`), the `category_fee()` resolver, the `fee_*` scalar getters, `deduct_transaction_fee` / `deduct_subscription_fee` / `create_ride_request` restated against it, and `admin_category_fee_catalogue()` / `admin_save_category_fee()` | **every provider is charged the same fee.** One global per-km rate meant a bajaj and a 40-tonne truck cost the platform the same to dispatch, and the only way to change it was a migration. Worse, the table is *not* on the `20260927000050` client-write allowlist, so it is a second independent lock — the fee editor writes only through the RPC |
| `0108` | `admin_registration_history` restated so `staff.user_id` ∪ `user_roles.ADMIN` are excluded from the USER branch and get their own STAFF category; signature and `RETURNS TABLE` unchanged | **the registration list is a mix of customers and staff**, and "18 pending" silently includes people who work here. The fix is a CTE, not a new column, precisely so the RPC's contract with the client does not change |
| `0109` | `staff_city_scope()` + `staff_scope_allows_city()` (empty array = unrestricted, mirroring `staff_category_scope`), `admin_staff_roster()`, `staff_activity_feed()`, `staff_city_scope_report()` | **a staff member's city is decorative.** `staff.city` was writable from the CEO's terms editor and enforced nowhere — worse than absent, because the manager who set it believes the queue below is scoped |
| `0110` | `admin_registration_history` restated with the city guard on all three branches | 0108 separates staff from persons, and 0109 introduces a city — but without this the queue is still global, so a Hawassa manager sees an Addis Ababa registration |
| `0111` | the five provider lifecycle actions restated (four from `00026`, `approve_provider` from **`00087`**, which has the welcome notification) with the city guard as a peer of the category guard | **a scope that filters a list but not its buttons is half a scope.** The queue is filtered, and the manager can still approve a provider in another city by id. `approve_provider` is deliberately NOT copied from `00026`: doing so is exactly how the welcome notification was lost once |
| `0112` | `staff_task_feed` and `verify_payment_proof` restated with the city guard; `provider_profiles_staff_registration_read` and `orders_staff_reports_read` re-issued with the city added | **the work queue and the money are the two surfaces the scope most obviously has to cover**, and neither did. The support-ticket and appeal branches are deliberately left unguarded because they are uncategorised — guarding an axis a row has no value for would hide the row entirely |
| `0113` | the provider **fulfilment gate**: `provider_documents_verified()`, `provider_fulfilment_blockers()` (returns *why*, not just yes/no), `provider_can_fulfil()`; `provider_can_publish`, `claim_ride` and `transition_order_status` all routed through it; `provider_fulfilment_gate_report()`; the `enforce_verified_documents` setting; `assert_provider_fulfilment_gate_is_wired()` | **a provider with an unreviewed ID and an unpaid activation fee could take a rider's trip and accept an order.** The document half of the gate was satisfied by *uploading* a document, because the status a document is born in is one the old predicate accepted; and `claim_ride` / `transition_order_status` never consulted the gate at all, while the buyer-side checkout — which did — refused the same provider |
| `0114` | `notify_best_effort()` (delivers, logs, never raises) and `notify_nearby_drivers()` (the capped fan-out); `create_order_secure`, `create_ride_request` and `claim_ride` restated to notify the counterparty; `assert_counterparties_are_notified()` | **a provider was never told an order arrived, no driver was ever told a ride was nearby, and a rider was never told their ride had a driver.** All three worked, which is why they survived: the counterparty found out by polling |
| `0115` | restates the six functions the first live Connectivity run flagged: `platform_transaction_fee` / `calculate_fare_estimate` re-wired through the category-aware resolvers, the `information_schema.yes_or_no` domain handled, and `assert_fee_switches_are_wired()` rewritten to read the pairs from 0073's own assertion | **the CEO's two fee switches were stored and inert** after 0107 restated their callers, and four assertions raised instead of measuring |
| `0116` | restates `assert_staff_city_scope_covers_the_task_feed()` with the derived-table wrapper removed, so `unnest(...)` is filtered directly | **the task-feed assertion raises `column "part" does not exist` (42703) on every call**, so the city-scope report cannot run — 0115 fixed the symptom's name and left the cause |
| `0117` | restates `create_provider_product` / `create_provider_vehicle` so the fulfilment gate refuses with `PROVIDER_NOT_FULFILMENT_READY: <reasons>` instead of a bare code, and adds `provider_listing_readiness()` | **a provider who cannot publish is shown `PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED`** — a machine token, no reason, no next step — after filling in a whole listing; the dashboard said nothing beforehand either |

**Three deploys, three different questions none of the gates could ask.** The
third was the instructive one: the *fix* for the second
(`FOREACH … IN ARRAY ARRAY[[…],[…]]`) parses fine and fails at runtime with

```
ERROR: multidimensional arrays must have array expressions with matching
dimensions (SQLSTATE 2202E)
```

because a nested `ARRAY[…]` constructor does not build a 2-D array in
Postgres. `pglast` accepts it — verified, along with two alternatives that do
build one. So the eventual form asks `pg_proc` for the overloads that exist and
grants exactly those, with no signature list to be wrong about. It is also
strictly more robust than the hand-written pair it replaced: adding a third
argument to one of these readers later now changes nothing.

**A guard anywhere in a file is not a guard on the loop.** The exemption that
keeps this check quiet about a correct pg_proc-derived loop was first written
as "does the file mention `FROM pg_proc`". 0107 mentions it **seven** times in
its assertion functions, so the hard-coded loop was exempted by an unrelated
catalog read and three falsifier cases passed green while proving nothing. It
is now scoped to the `DO $$` block that issues the GRANTs.

That was the third time in this session a falsifier passed for a structural
reason rather than a testing one — twice from an anchor matching text a later
edit deleted, once from an exemption matching something too broad. Every case
that mutates a literal now asserts its anchor, and asserts that its mutation
changed the file and removed the guard it meant to remove. **A falsifier that
cannot prove it did anything is worse than no falsifier**, because it is
counted in the number.

**Parsing proves nothing about names.** Two deploys died on the same file,
both after it had parsed clean as a whole *and* body by body:

| Run | Error | Why no parser sees it |
|---|---|---|
| 1 | `syntax error at or near "." (42601)` | a function call qualified like a row |
| 2 | `function fee_ride_base_fare(uuid, text, boolean) does not exist (42883)` | a **name that resolves to nothing**, granted by a dynamic statement |
| 3 | `column "part" does not exist (42703)` | a **column** that resolves to nothing — the derived table projects the constant `1` |

The second is the instructive one. 0107 granted privileges in a `DO` block over
ten fee readers, and granted **both** `(uuid, text)` and
`(uuid, text, boolean)` for all ten — but only `fee_commission_percent` and
`fee_commission_min` take a third argument. The other eight therefore named a
function that did not exist, and Postgres resolves `ON FUNCTION` at execution
time, so the push aborted. Nothing about that is a syntax question: the
statement is perfectly well formed and both parsers said so.

The loop now consults `pg_proc` and touches only overloads that exist, so adding
a third argument to one of these readers later cannot break the deploy the way
the hard-coded pair did. `check_dynamic_privileges_name_real_signatures()` fails
the build on an unguarded loop that names a function or an arity the file never
creates — and deliberately stays quiet about a *guarded* one, since there a
missing overload is the loop working as intended rather than a defect.

Row 3 is the column half of the same class, and it cost **two more** deploy
cycles. 0112 wrote `AS x` where it meant a column, and wrapped the expression in
a derived table that projected the constant `1`; 0115 answered the diagnostic by
*naming* the column (`AS x(part)`) while leaving the subquery wrapped, so the
derived table still had no `part`. Both statements parse — `pglast`, the
whole-file parse and `plpgsql_body_syntax.py` all accept them — because
resolution is not a parsing question: the name only has to exist when the
statement runs, and the live run said `column "part" does not exist`.

`tools/harness/column_scope.py` closes it, and it is the first gate here built to
be **quiet first**. It judges a reference only when EVERY relation in scope is a
derived table or a CTE whose SELECT list is constants, plain column names, or
aliases. A base table, `unnest` in FROM, `VALUES`, `SELECT *` or an unaliased
function result makes the scope UNKNOWN and the whole statement is skipped, so an
unrecognised relation can only ever **suppress** a finding, never invent one — and
plpgsql variables (the DECLARE section and the signature's parameters) are
collected and excluded, because PostgreSQL would resolve such a name to the
variable. A qualified reference is judged only when its qualifier is one of the
known relations, so `public.some_table.col` stays silent.

Run `--all` over the 204-migration history, it reports exactly the four shipped
statements and **nothing else**, which is the evidence that it is not simply a
louder check. `falsify_column_scope.py` pins both shipped shapes red and the five
that only look like them green — the fixed `unnest` shape, a derived table that
really has the column, a base table, a DECLARE variable, and a CTE column.

Fixing it surfaced the failure mode this harness keeps hitting, and it is worth
naming precisely: **a falsifier anchored on a string a later edit removed goes
green forever.** Case C of `falsify_rpc_grants.py` had deleted two literal
`GRANT` lines; rewriting the loop to build its signature from `pg_proc` deleted
those exact lines, so the case was still deleting them — and proving nothing.
An `assert anchor in …` guard now runs before every case that mutates a
literal, so a stale anchor fails loudly instead of passing quietly. The same
rewrite broke the *check* too: its dynamic-privilege pattern matched
`%I(...)`, so once the loop interpolated `%s` it read **zero** dynamic
privileges from the file and would have missed a genuinely deleted grant.

**A `LANGUAGE sql` body is as invisible to pglast as a plpgsql one.** The whole-file
parse passed; the deploy then died with
`ERROR: syntax error at or near "." (SQLSTATE 42601)` at statement 16 of 0107.
Ten scalar fee readers opened with

```
WHERE f.id = (SELECT public.category_fee(p_category_id, p_city).id))
```

A function call cannot be qualified with `.id`. It parsed clean because `AS $$
… $$` is a *string literal* to the file parser, and `plpgsql_body_syntax.py` —
the gate written for exactly this blindness — only looked at bodies whose
opening statement said `LANGUAGE plpgsql`. The eight migrations the gate did
read were fine; the one it skipped was the one that broke. It also read the
`FROM public.category_fee f` *function* as though it were the *table*
(`category_fee_settings`).

So the gate now parses both languages, and judges them differently, because the
repair it applies to plpgsql is a corruption when applied to sql:
`SELECT ... INTO v` is an assignment in plpgsql and a real `SELECT-INTO` in sql,
so plpgsql normalisation must not touch sql bodies; and the `SQL_COMMAND`
allowlist — which exists to filter plpgsql noise — must not filter sql bodies,
where an unrecognised leading keyword *is* the finding.

That last change needed a falsifier of its own, and the first case for it was
wrong in a way worth recording: it used `SELECT ... INTO v`, which **pglast
accepts**, because that is Postgres's own table-creating `SELECT-INTO` and is
valid in both languages. The case stayed green for a reason that had nothing to
do with the gate. `RETURN` is the genuinely plpgsql-only construct.

Fixing the 800-character prefix window while there also removed **18
pre-existing false positives** across applied history, and the new `LANGUAGE sql`
path reports zero across all 310 migrations — so it is not simply a louder
check. `falsify_sql_body_syntax.py` cases A–E pin all of it.

**A refactor that keeps every gate green and drops behaviour.** 0107-0114
applied cleanly. Then Connectivity ran against the real schema: **76 passed, 6
failed.** The six are worth reading as three kinds, because only one of them was
a parsing problem:

| Kind | Findings |
|---|---|
| **regression** | 0073 wired `fee_enabled_transaction` into `platform_transaction_fee` and `fee_enabled_ride` into `calculate_fare_estimate`. 0107 restated both as delegations to new category-aware resolvers — a correct refactor — and the switch reads went with the old bodies. **Both of the CEO's switches were stored and inert** |
| **runtime** | a function call qualified with `.id`; `bool_and()` over the `information_schema.yes_or_no` domain; `AS x` naming a *table* where a column was meant (`column "x" does not exist`); and `orders.order_number`, a column from migration 0037, which is **below the baseline** and so was recorded as applied *without ever being executed* |
| **false red** | two of my own assertions |

The last row of the middle band is the trap this repo keeps setting: 0037
created `order_number`, `order_number_sequences` and `allocate_order_number()`,
and none of them exist on the live database. 0114 read `orders.order_number` and
so **failed every order creation** — the one path the product cannot survive.

Two of my assertions were red on correct code, which is worse than no check
because it teaches people to ignore red. Both searched a whole function *body*
for a needle a correct body also contains: `MANUAL_REVIEW` appears in
`coalesce(d.verification_status, 'MANUAL_REVIEW')` **before** the accepted
`IN ('AUTO_APPROVED', 'VERIFIED')` list, so `'%MANUAL_REVIEW%AUTO_APPROVED%'`
matched; and `find_nearby_drivers` sits one level down, inside
`notify_nearby_drivers()`, so requiring it at the call site flagged a working
function. The needles now mirror the structure: the docs check inspects only
`IN (...)` lists, and the ride check follows the helper and verifies *it* still
reaches the fan-out.

Fixing these broke **three falsifiers**, every one for the reason this project
keeps re-learning: **an anchor that a later edit invalidates passes while
proving nothing.** 0115 restates six functions, so each falsifier's mutation
landed in an older file that the check no longer reads. Two of the three also
exposed a *check* with the same flaw — `check_category_fees_are_wired` located
its storage migration as "the last file mentioning `category_fee_settings`",
which 0115 mentions in a comment. Both now go through one shared
`category_fee_storage_migration()`, and mutation-based cases use
`authoritative_patch()`, which raises on a missing anchor instead of returning
an empty patch. `check_fee_switches_survive_restatement()` reads the
(function, switch) pairs **from 0073's own assertion** rather than retyping
them, and searches the function body rather than the file — its first version
searched the file and passed a mutation that deleted the switch, because
0115's comments still named it.

**A static check cannot find a Dart compile error.** 39 checks, 12 falsifiers
and four gates all passed while the app did not compile. The gap was structural,
not an oversight: `tools/harness/static_checks.py` reads Dart as *text*, so
every check in it is a regex over source. Nothing in it can know that `"…$"`
inside a string literal is an interpolation with no identifier, that GoTrue
exports an `AuthState` that collides with the app's, or that
`DropdownMenu.onChanged` hands you a `String?` when your handler declared a
`String`. Dart code that reads correctly and is *wrong* is exactly what a regex
approves of.

The escape is not a better regex — it is the compiler. Flutter stable is
downloadable with no account:

```
curl -sL -o f.tar.xz <base_url>/flutter_linux_<v>-stable.tar.xz
tar -xJf f.tar.xz -C /tmp/flutter_sdk
export PATH=/tmp/flutter_sdk/flutter/bin:$PATH
flutter pub get && flutter analyze --no-fatal-infos --no-fatal-warnings
```

Run on first use, that reported **7 errors** in code this harness had called
green, across three of the session's own files:

| Error | Why no check could see it |
|---|---|
| 5x `Expected an identifier` in `geocoding_service.dart` | the Overpass regexes end in `…\|town)$"`. A bare `$` before `"` is an interpolation opener, so a string that reads as regex data is a syntax error. It needs `\$` to reach Overpass as an anchor |
| `ambiguous_import` in `admin_dashboard.dart` | GoTrue and `auth_provider.dart` both export `AuthState`. Only one has `.profile`, and only the compiler knows which name resolves to which |
| `argument_type_not_assignable` in `category_fee_settings_screen.dart` | `_selectCity(String)` against `ValueChanged<String?>`. The sibling `_selectCategory(String?)` was already correct, so the file looked internally consistent |

After the three fixes: **0 errors, 230 tests passing.** `flutter analyze` is
now the strongest gate in the project and it should be run *first*, before any
harness, because everything else in this section assumes the Dart compiles.
`flutter build bundle` additionally needs the Android SDK and cannot run in a
bare sandbox; `analyze` plus `test` is the achievable floor.

**Two of the falsifier's cases were green for the wrong reason, and one of the
check's own rules was backwards.** `REVOKE … FROM PUBLIC` withdraws the
*implicit* default grant and nothing else — it does not revoke a grant made to a
named role, which is why `GRANT … TO authenticated` four lines earlier was being
erased and `fee_switch_state` and `list_staff_jobs` were both reported
unreachable. And the scan ran over raw SQL, so `00083`'s line-14 `--` comment —
which *documents* the revoke it wants — was counted as the statement itself.
Both are now modelled correctly, with `falsify_rpc_grants.py` cases F/F'/F''
pinning them. The falsifier's own case C was wrong twice before it was right:
first it appended `authenticated` to a revoke the loop re-grants two lines
later, then it deleted one of the two overload grants and the other still
carried the privilege.
| — | no migration: the two redirect loops were Dart-only. `tools/harness/redirect_cycle_simulation.py` now searches the router's rules for cycles | `GoException: redirect loop detected` — `/ => /complete-profile => /user => /complete-profile` |

**0080 before any build that ships the liveness client.** The client inserts
the new columns; if they are absent, every document upload fails.

**A bucket is only as deployed as the migration that creates it.** `0012`,
`0017` and `0033` are all below the workflow's baseline, so the workflow records
them as applied and never runs them; the four buckets that work today work
because they were pasted into the SQL editor, and the two that were not pasted
(the gallery, and `vehicle-images`) did not exist. `0096` re-declares those five
with `ON CONFLICT DO UPDATE` and `0097` adds the sixth (`vehicle-images`) the
same way, so the set no longer depends on that history, and
`check_client_buckets_are_created()` fails the build if a bucket named in `lib/`
is created only by a pre-baseline file. The failure mode this guards against is
the one that shipped: `grep provider-gallery supabase/migrations/` found a
creation statement and looked reassuring — in a file that is never executed.

**The activation fee is income, and `0098` is what proves it.**
`approve_wallet_recharge` withholds the one-time `provider_registration_fee`
from a provider's first approved recharge and records it as `platform_fee` on a
`RECHARGE` ledger row — not a `TRANSACTION_FEE` and not a `SUBSCRIPTION_FEE`. A
reader that filtered on those two types only therefore rendered a confident
`ETB 0.00` while the money had been collected. The read side is fixed (there are
now two income readers, and `check_income_readers_count_every_fee_type()` fails
the build if either stops counting `RECHARGE`); the write side is
`assert_activation_fee_writes_income()`, the only test that drives the
withholding branch — the existing wallet write test deliberately sets
`registration_fee_paid = true` to keep its arithmetic simple. The three
read-only money assertions (`assert_recent_approved_recharges_credited` and the
ride/order fee checks) are existential negatives that pass with zero rows, which
is why `assert_income_covers_every_fee_type()` returns the live figures, fails on
impossible arithmetic, and says so when the ledger is empty.

#### 7.1.1 The gates check what a deploy would apply, not the newest file

`sh build/run_all.sh` runs six gates. Two of them read SQL, and both were scoped
to `--recent 1`: the newest migration, the one being authored. That is right for
a single file and wrong as a statement of intent, because the question the gate
answers is not *"is the file I am typing clean?"* but *"is everything I am about
to push to the live database clean?"*. The two diverge as soon as more than one
migration is waiting — a batch of three, each checked the day it was written,
goes out in one `db push`, and none of them was ever checked in the shape it is
deployed in.

`tools/harness/pending.py` fixes it. The boundary is `supabase/DEPLOYED_HEAD`,
a committed file holding the filename of the newest migration a deploy actually
**applied** — not merely ran, since a no-op deploy logs `Remote database is up
to date` and applies nothing. It is updated as step 1 of §7.5, by the same deploy
it describes.

Two rules keep the fix from being its own quiet failure:

- **A missing, empty, or unknown boundary is fatal**, not "check nothing". A
  window that silently collapses to empty reports success without having looked at
  anything, which is worse than no gate — `--recent 1` was wrong in exactly that
  direction and the fix must not reintroduce it through a missing file.
- **An empty window falls back to the newest migration and says so.** When
  everything is deployed (the state right now) the gate still checks one file and
  prints `note: nothing is pending … re-checking the newest 1 so the gate is never
  vacuous`. A gate whose scope is empty has proved nothing.

`falsify_pending.py` has 20 cases covering exactly those: the fallback, a pending
migration being in the window, each of the three unusable-boundary states
failing both gates, and — the case that matters — a real defect planted in the
**second** of two pending migrations turning the gate red end to end, while the
same migration placed *behind* the head is correctly not judged. That pair is the
difference between a real gate and a re-labelled `--recent 1`.

#### 7.1.2 A repair restatement is judged by the mirror assertion
`restated_body_diff.py` proves a restatement is a pure **superset** of the body
it replaces, with every added line an approved scope guard. 0116 is the case that
rule cannot express: it *fixes* a defect, so its dropped lines are the point, and
the superset check would (correctly) reject it for doing its job. Leaving it
unpinned was the real gap — the defect could be reintroduced by a later
restatement, or half the repair undone, and nothing would notice.

So `FIXES` asserts the complement, just as tightly:

1. the repaired body **contains** the working statement,
2. it does **not** contain the shape that was broken (`from ( select 1 from
   unnest`, and `as x(part)` — the alias-list answer that did not work either), and
3. **every line that differs** between the two bodies mentions an identifier the
   broken statement is made of (`v_cat_guard`, `v_city_guard`, `unnest(`, `part`),
   so a repair that quietly reformats, reorders, or drops anything else is RED.

Rule 3 is a vocabulary, not a list of literal lines, so re-wrapping the fix for
readability needs no edit; the presence/absence needles drop all whitespace for
the same reason. `falsify_restated_body_diff.py` cases H–L prove the rule bites:
the revert to `AS x`, the subtler revert to `AS x(part)` (`part` is a real name —
the defect is that the derived table has no such column), a **half** repair that
looks fine on a read-through, a repair that also drops the missing-function check,
and a legitimate re-wrap that stays green. 12/12.

#### 7.1.3 The check that was green for the whole life of the bug

**A provider could not upload a product, and no test said so.** The route
existed, the form existed, the RPC existed and was granted, the dashboard linked
to it — and pressing Save produced this, once per attempt:

```
PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED
```

Two independent defects sat behind it.

**The refusal said nothing.** `create_provider_product` and
`create_provider_vehicle` came from `20260924000004`, above the deploy baseline,
and migration 0113 gave `claim_ride` and `transition_order_status` the
reason-carrying pattern. The two CREATE paths were restated for the gate and
never for the *message*, so the one surface a new provider touches first is the
one surface that names no reason. Migration 0117 fixes it and adds
`provider_listing_readiness()` so the state is readable before the form is.

**The client's gate and the server's gate disagreed.** `ProviderDocGate` is
client-side and fail-open, and it counts a document in `MANUAL_REVIEW` as
accepted — deliberately, so an admin's review queue never locks a provider out
of their own business. `provider_documents_verified()` (0113) accepts only
`AUTO_APPROVED` / `VERIFIED`, because a document row is *born* in
`MANUAL_REVIEW` (column default plus a BEFORE INSERT trigger), so the old
predicate was satisfied by uploading an ID.

That contradiction is the mechanism: the client said yes, so the provider filled
in the entire form, and the server — the one that decides — refused at Save.
`ProviderReadiness` now asks `provider_fulfilment_blockers()`, the same function
the gate itself calls, so what the dashboard shows and what the server enforces
cannot drift. It reports "unknown" when it cannot ask, because a green "you can
publish" on an unreachable server is the same lie in the other direction.

**And the check that should have caught it was a hand-written list.**
`check_server_refusal_codes_reach_the_user()` asserted three specific codes, and
`PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED` was not one of them — so the suite
was green for the entire life of the bug. A curated list of "the codes that
matter" decays in exactly one direction.

`check_publish_refusal_is_actionable()` replaces that habit. It **derives** the
functions: it scans the provider screens for `create_provider_*` RPC calls, reads
each one's latest definition, and requires every code that function can raise to
be translated. Three things must hold, because each has been false
independently: the create functions raise the reason-carrying code, every code
they can raise is translated, and the provider can see the block before typing
anything. Its own vacuity guard is deliberate — if discovery finds nothing, the
check goes RED, because a derived check that quietly inspects nothing is worse
than no check.

`falsify_publish_refusal.py` is 9 cases, and **two of them found real weaknesses
in the new check on its first run**: matching the RPC *name* rather than the RPC
*call* (a readiness path that asked the client still passed, because the name
survived as an argument), and searching the dashboard source without stripping
comments (commenting the banner out left its name behind). Both are fixed in the
check. That is the whole argument for writing the falsifier.

Changing this also broke two existing falsifiers, which is the rule working.
`falsify_fulfilment_gate.py` case H anchored on the single-line literal
`['provider_not_fulfilment_ready']`; 0117's edit made it multi-line, so
`str.replace` silently matched nothing and the case passed while proving nothing
— the exact hazard this repo has hit three times. It now raises on a missing
anchor. `falsify_pending.py` case G asserted the applied-marker was the *newest*
migration, which is backwards: the marker is supposed to be behind the working
tree while a migration waits to deploy, so writing 0117 made it go red on
correct behaviour, and the tempting fix would have been to move the marker and
lie about what the live database has.

**A policy page has to be a page, and it has to be true.** Google Play rejected
the listing with *"account deletion page is down, or includes geographical
restrictions, or the URL is incorrect"*, and all three were true of
`delete-account.md`: a markdown file in a private repository is not a page, and
it described an email address and a seven-day promise instead of the flow the
app actually ships (`request_account_deletion`, migration 20260927000054, and
`AccountDeletionScreen` behind Profile → Delete Account). Nothing in the
repository could tell the difference between a truthful page and a plausible one,
so there was nothing to fail.

`docs/delete-account.html` is the page: one self-contained file, no form, no
script, no remote asset, no country check, and a link to it from
`docs/index.html` so the published root is not a dead end.
`check_account_deletion_page_is_public_and_true()` holds three things at once,
and each has been false on its own:

1. **Public in the mechanical sense Play tests for** — one file, no form, no
   `input`, no `<script>`, no `http-equiv`, no `src`/`href` to another host. A
   login wall is the same defect as a geo wall: both mean a reviewer without an
   account sees nothing.
2. **The instructions match the app** — every label the page tells a user to tap
   or type is matched against the screen that calls
   `rpc('request_account_deletion')`, found by search rather than named here, so
   the page cannot describe a control that does not exist. The menu step is
   additionally required to exist as a real `context.push('/account/deletion')`.
3. **The deleted/kept split is the schema's split** — `_foreign_key_actions()`
   walks every migration and returns each table's ON DELETE action, and
   `_deletion_cascade()` closes over CASCADE from `auth.users`. A table the page
   claims is deleted and the database does not delete is a **hard failure**:
   over-claiming erasure is a lie to a policy reviewer. Under-claiming is not,
   which is why the completeness rule runs the other way — every table the app
   reads must be listed as deleted, retained, or **conditional**, and the
   conditional bucket is only legal for tables the schema genuinely splits.

That third bucket is not a convenience. `wallet_recharge_requests` cascades with
the provider wallet *and* is nulled out of `approved_by`: a business account
loses the row, a customer account keeps it. `staff_activity_log`,
`staff_job_assignments`, `staff_warnings` and `staff_task_completions` have the
same shape, and `referral_codes` a fifth. Filing any of them under a single
bucket states something false about half the accounts, which is why the check
derives the split set and requires the page to match it exactly.

**Three things were wrong before the check was right**, and all three were
found by the falsifier rather than by reading:

- The first derivation merged foreign keys by taking the **strongest action ever
  seen in the history**. `user_documents` was therefore pinned to the CASCADE in
  0022a forever, and case J — which changes a migration instead of the page —
  stayed green. The state is now tracked per `(table, parent, column)` with the
  last statement winning, and the per-parent answer is the strongest of its
  columns, which is what `appeal_cases` needs (`user_id` CASCADE *and*
  `resolved_by` nullable: the row goes, the nullable column is never consulted).
- The merge also compared ranks *before* storing, so every plain `NO ACTION`
  edge was discarded — and a NO ACTION key on a nullable column is the entire
  "kept, link nulled" case. `wallet_recharge_requests.approved_by` was invisible,
  which is how a table that survives deletion nearly got filed under "deleted".
- `ADD COLUMN … REFERENCES auth.users(id)` is a foreign key, and reading only
  the `ADD CONSTRAINT` form hid every one of them.

The page also had to be corrected for something no check was looking at: the
audit tables null the *link* but keep a denormalised **name** on the row
(`staff_activity_log.actor_name`, `staff_warnings.warned_by_name`,
`staff_job_assignments.assigned_by_name`), and `support_tickets` keeps
`reporter_phone` while `orders` keeps `delivery_address` and `ride_requests`
keeps the pickup and destination the user typed. The page says so plainly
instead of claiming no name is retained — the honest version of the claim is
worth more to a reviewer than the flattering one, and the flattering one is
false.

`falsify_account_deletion_page.py` is 16 cases. Case J is the one that matters:
it edits a **migration**, so a green run cannot be explained by the check having
memorised today's answer.

### 7.1.4 Nothing may block the account deletion

**0054 detached the eight columns that were loud and left the ones that were
quiet, and the quiet ones block just as hard.** Its header says the eight it
converted were "`NOT NULL` with no action", and then reasons that a NULLABLE
column "simply stops matching", as though nullability were the thing that
mattered. PostgreSQL 18, §5.5.5:

> The default ON DELETE action is ON DELETE NO ACTION […] the foreign-key
> constraint is still required to be satisfied, so this operation will usually
> result in an error.

and, in the next paragraph, the exemption that is easy to misread as permission:

> Normally, a referencing row need not satisfy the foreign key constraint if any
> of its referencing columns are null.

That is about **writing** a referencing row whose column is already null. It is
not a licence to delete the parent while a row still points at it. A nullable
`audit_logs.actor_id` is exactly as blocking as a NOT NULL one.

So `delete_user_account` ends in `DELETE FROM auth.users` and dies with

```
ERROR: update or delete on table "audit_logs" violates foreign key
       constraint "audit_logs_actor_id_fkey" on table "audit_logs"
```

for any account holding an audit row — and 0035 put a trigger on the mutation
paths, so that is **every account that has ever done anything**. The order of
operations makes it worse than a failure: the RPC has already written APPROVED
and the notification before the gateway calls the cascade, so the request ends
up APPROVED for an account that still exists. That is the one state the design
said it was avoiding.

The business side was never touched at all. `provider_profiles` is CASCADE from
`auth.users`, and seven keys point into that subtree with no action — including
`orders.provider_id`, which is NOT NULL, so a shop with one order could never be
closed and the error names `orders` rather than the person asking to leave.

**0118** (`20260927000118_nothing_blocks_the_account_deletion.sql`) detaches
twenty columns — seven business-side, thirteen account-side — in one DO block
driven by a `('table', 'column')` VALUES list. It looks the key up on the
child's own column and **takes the parent from `pg_constraint.confrelid`**,
because the migration connection cannot resolve the `auth` schema and a
hand-written parent name aborts the push. It skips keys that are already CASCADE
or SET NULL, so re-running it is a no-op rather than a re-drop of a correct
constraint. And it ends with a verification block that raises
`ACCOUNT_DELETION_STILL_BLOCKED` if any of the twenty is not now a SET NULL key —
**a migration that silently skips is worse than one that fails**, and this one
would otherwise have deployed cleanly having fixed nothing, exactly as 0054 did.

### Two deploys, and what the file now says it cannot do

0118 failed to deploy twice, and both failures are worth recording because
neither is visible to `flutter analyze`, to the static harness, or to review:

| Run | Error | Cause |
| --- | --- | --- |
| 36870164815 | `relation "auth.users" does not exist` (42P01) | the list named the parent; the migration connection's `search_path` does not resolve `auth` |
| 36873453231 | `record "target" has no field "parent"` (42703), then 42P01 again | `%I` on a `regclass` |

The second is the instructive one. `format('%I', some_regclass)` does **not**
quote a relation name; `regclass` renders as the *string* `auth.users`, and `%I`
quotes that whole string as one identifier, producing `REFERENCES "auth.users"` —
a relation literally named `auth.users`, which does not exist. It worked for the
first seven tuples purely by luck: their parents live in `public`, which the
`search_path` does resolve, so they rendered bare and happened to be valid. The
fix is to rebuild the name from the catalog — `format('%I.%I', pn.nspname,
pr.relname)` from `pg_class`/`pg_namespace` — which names the parent without
writing `auth` anywhere in the file.

**A local PostgreSQL scratch cluster is how these get caught.** `apt-get install
postgresql-14`, a cluster on a unix socket (`pg_ctl -o '-k /tmp/pgrun -p 5433
-c listen_addresses='`, so nothing listens on TCP), a hand-written slice of the
real FK graph, and then `psql -v ON_ERROR_STOP=1 -f` over the migration in
question. `su postgres` cannot read anything under the project directory, so the
migration is copied to `/tmp` and `chmod 644` first. Running all three pending
migrations against an empty database is what surfaced **four** further defects
that a review of the diff would not have:

1. 0118's verification block declared `target record;` and then used
   `target.tbl` as a VALUES alias — `record "target" is not assigned yet` (42703).
   The `FOR … IN` loop in the first block is what makes that name legal there.
2. `account_deletion_blockers()` referenced the recursive CTE inside a subquery
   (`(SELECT rel FROM gone LIMIT 1)`), which is `recursive reference to query
   "gone" must not appear within a subquery`. The arm was redundant with the
   JOIN below it.
3. 0119 put `COMMENT ON COLUMN public.profiles.avatar_storage_path` **above**
   the guarded `ADD COLUMN`, so it works only on a database that already has the
   column — the one case it exists for. Every earlier run found the column
   present, so the order was never exercised.
4. 0120's evidence `CHECK` and its `INSERT` both name `appeal_cases.email`, and
   no migration ever added the column: `column "email" does not exist`.

Executing 0119's and 0120's functions found three more, none of which a
`CREATE FUNCTION` will catch because plpgsql resolves names on first call:

- `assert_profile_avatar_surface()` read `polqual` and `polrelid` off
  `pg_policies`. Those are the **`pg_policy` catalog's** column names; the view
  exposes `qual` and `with_check`, and those are already deparsed text — it is
  defined as `pg_get_expr(polqual, polrelid) AS qual`. So there is nothing to
  call `pg_get_expr` on at all. It also read `qual` alone for the INSERT policy,
  whose test lives in `with_check`, so it reported "no insert policy exists"
  when one plainly did.
- `request_password_reset_appeal()` recovered the id of the row it had just
  inserted with `(SELECT max(id) FROM appeal_cases …)`. PostgreSQL has **no
  `max(uuid)`**, so every real caller got `function max(uuid) does not exist`
  from the one function meant for somebody who cannot sign in. Nothing about that
  feature could ever have worked. It is now `RETURNING id INTO v_case`.
- `account_deletion_blockers()` answered `ok` locally, and that was correct — but
  only because of fix 5 below.

### The twentieth column, and the false green that hid it

`admin_notification_broadcasts` has **two** keys to the account table:
`admin_id`, which 0118 detaches, and `target_user_id`, which is nullable with no
`ON DELETE` action at all — precisely the shape 0054's header calls survivable
and 0118's own header calls a blocker. The harness reported zero blockers
anyway, because `_foreign_key_actions()` collapsed each table to the
**strongest action per parent**: one SET NULL column made the whole parent read
SET NULL and the NO ACTION sibling disappeared.

That is the same failure as 0054, one level up, and it is why the blocker list
is now computed **per column** (`_FK_COLUMN_ACTIONS`). The per-parent collapse is
still what the CASCADE closure walk wants — that is a question about the parent,
not the column — but a parent is only as safe as its weakest column. Falsifier
case **Q** drops the `target_user_id` tuple and asserts the check goes red; under
the old per-parent reader it stayed green.

**`check_account_deletion_is_unblocked()`** is the static half, and
`falsify_account_deletion_page.py` cases M–Q cover it. Two things it had to get
right first, both of them the shape of a false green:

`provider_profiles.user_id` is deliberately **not** in the list. It is a NO
ACTION key onto `profiles` and looks like a blocker, but `provider_profiles` is
reached only through `auth.users.user_id ON DELETE CASCADE`, so the only rows
that can reference the dying profile row are the rows being deleted in the same
statement. Relaxing it would drop NOT NULL on the column the entire app finds a
provider by, to fix a problem that cannot occur.

The migration also adds `account_deletion_blockers()`, which asks the **live**
catalog rather than the migration history — a constraint added by hand in the
Supabase dashboard never appears in a file. The connectivity suite asserts it
returns `ok`, and it is granted to `anon` for the same reason
`assert_ceo_delete_is_wired` is: the suite runs as anon, and a diagnostic the
reading role cannot call answers PGRST202, which is indistinguishable from a
migration that was never applied.

**`check_account_deletion_is_unblocked()`** is the static half, and
`falsify_account_deletion_page.py` cases M–P cover it. Two things it had to get
right first, both of them the shape of a false green:

- The first attempt to read 0118's detach list searched for
  `FROM (VALUES …) AS v(a, b, c)` anywhere in the history. It matched **285
  tuples** — status transitions, fee settings, connectivity-test expectations —
  and reported "nothing blocks the deletion" on a schema where `orders.provider_id`
  was still a NOT NULL NO ACTION key. It is now scoped to a `DO $$ … $$` block
  that drops and re-adds a foreign key, which reads **19**.
- A curated copy of a list the file already states is a second thing to forget:
  0118 shipped nineteen columns while the harness still believed 0054's eight,
  which is how `orders.provider_id` came back out of the derivation as a
  published blocker. The reader now takes the migration's own tuples, and
  `_unreadable_detach_blocks()` reports a block it can see but cannot read a
  single name from, because silence from a broken pattern looks exactly like a
  clean schema. It reads **20**.

**Ordering.** `supabase/DEPLOYED_HEAD` stays at `…0117` until a deploy log
actually says `Applying migration 20260927000118…`. The public deletion page
describes the post-0118 behaviour, so **0118 has to be applied before the page
is submitted to Play Console** — otherwise the page promises an automated
business closure that the live schema still cannot perform.

### 7.1.5 Every transaction leaves a document, and content can be taken down

Two migrations, both written after a defect was found by running the code
rather than reading it.

**0121 — `transaction_documents`.** The reported state was "full document
prepared and stored end to end for every transaction, every scenario, with the
necessary slips and both parties' information". What existed was
`order_status_history` and `ride_status_history`: who moved the row, when, from
which status. No amounts, no counterparty, nothing a person could hold, and no
receipts table anywhere in the schema.

The seam is **AFTER INSERT on the two history tables**, not a restatement of
`transition_order_status` / `transition_ride_status`. 0088 already records what
a missing branch in that transition costs: a ride frozen in a state nobody can
move out of, with no fee ever charged. One trigger per history table covers
every scenario that exists today and any a later migration adds. AFTER, not
BEFORE, so a transaction that rolls back takes its document with it — a slip for
an order that never existed is worse than no slip.

Both parties are **snapshotted**, not joined: a slip that reads its parties
through a join changes when the parties change, which defeats the purpose. The
fee is read from `wallet_transactions`, not recomputed from the resolver —
the resolver is what *would* be charged, the ledger is what *was* taken. The
`transaction-slips` bucket is **private**, unlike every image bucket in the
project, because a slip carries a delivery address and two phone numbers.

**The assertion had to be rewritten once.** Its first form asked "does this
subject have any document?" — a question about the *subject*, not the event.
Three status changes produce three history rows and three documents, and
deleting any one of them still leaves two, so every history row still found a
document and the check reported `ok`. It was proved wrong by deleting a document
and watching it stay green. It now compares **counts per subject**, which
catches a trigger that did not fire and a document that went missing.

**0122 — content control.** `suspend_provider()` existed; nothing could remove
a single uploaded image and nothing recorded what was done. An administrator
looking at a photograph that breaks the terms had two options — leave it up, or
delete the provider — and the second is far too destructive to reach for over a
picture. `admin_moderate_image` deletes the **referencing row and the storage
object in one call**, because every image in this project is referenced by a row
and removing only the object leaves a row pointing at nothing that renders as a
broken image forever. `admin_suspend_account` writes `profiles` AND
`provider_profiles`: the router gates on `profiles.status`, the admin panel
reads `provider_profiles.status`, and the half-written state is exactly what
`assert_profile_status_synced` exists to catch.

Three bugs in 0122 were found only by executing it against the local
PostgreSQL, and every one of them made the feature dead on arrival:

- the bucket membership test was `p_bucket <> ANY (ARRAY[...])`. `<> ANY` is
  **AND**-semantics, so a bucket that *is* on the list read as not moderable
  and every takedown raised `THAT_BUCKET_IS_NOT_MODERABLE`. It must be
  `<> ALL`. This is the single most-missed operator in SQL, and it reads as
  correct;
- the `ADD CONSTRAINT` calls were unguarded, so a re-run died with
  `constraint ... already exists` — which is how a broken first attempt would
  have been unable to be fixed. Both 0121 and 0122 now add constraints only
  when absent, and use `%s` (not `%I`) for an already-quoted relation name,
  because `%I` on `"public"."users"` reproduces the 42P01 that killed two
  deploys;
- `actioned_by_name` is NOT NULL, and `SELECT ... INTO` a name matching no row
  writes NULL over the `''` default — so an administrator without a `profiles`
  row yet could not remove an image at all.

**The reported "icon does not open".** `category_fee_settings_screen.dart`
wrote its permission flag *after* the final `setState`:

```dart
setState(() { _rows = ...; _loading = false; });
_canEdit = await _readEditorFlag();
```

A field assigned after the last rebuild never reaches the widget tree.
`_canEdit` stayed `false` for the life of the screen, every control gated on it
was dead — the category dropdown's `onChanged` was `null`, so no category could
be selected and no fee section ever rendered — and the screen told the **account
owner** that only the account owner could change what the platform charges.
Every route, card and GRANT was correct. From outside, that is indistinguishable
from a card that does not open.

`flutter analyze` cannot see it: the field is read, so it is not "unused", and
the assignment type-checks. Only the **order** of the two statements reveals it.
`check_permission_flags_reach_the_widget` now looks for that shape anywhere in
`lib/`, and `falsify_permission_flag.py` puts the defect back into a copy of the
tree and requires the check to go red — nine cases, including this one. The
first run of that falsifier found a `NameError` in the check itself, which is
the argument for having written it.

### 7.1.6 The end-to-end audit: four failures, one shape

A report that sections built well were not working end to end. All of it turned
out to be one shape of defect, repeated: **a thing existed, was correct, was
granted, and could not be reached.** None of the four was a compile error.

**The category fee: "the category may have been removed".** The fee editor
called `admin_save_category_fee` with fifteen named arguments. Thirteen came
from a `for (final f in [...]) f.param: ...` element over declared `_FeeField`
lists, and one of the two literal keys was fine — but the list declared
`p_booking_base_fare` where the database has declared `p_booking_base_fee`
since 0107. **PostgREST matches named arguments by name**, so a single wrong
letter in a fifteen-argument call is `PGRST202`, and `friendlyError` renders
`PGRST202` as *"That item could not be found. It may have been removed."* — a
sentence about a missing category, caused by a misspelt parameter.

Two things had been believed about this bug and both were wrong. `ON CONFLICT
(category_id, city)` matches `category_fee_settings_unique`, and the function
body exists and raises its own refusals. Neither is relevant: the request never
reached the body. Nothing but comparing the client's keys against the live
catalog's `proargnames` could have found it.

The check that found it, `check_admin_rpc_argv_is_transcribed`, had been
**reporting the mismatch for days and was not reading the dynamic half**. Its
collection-for branch skipped comparison entirely, because a map built by a loop
cannot be enumerated from the source — and the thirteen arguments it skipped
were the majority of the call. The bug was sitting inside the one branch written
to excuse itself. That branch now resolves the declared lists and compares them
too, and the *success* path needed its own `continue`: without one the check
compared the two literal keys again after the dynamic comparison had already
passed, and reported a green call site as broken.

**The admin password.** `account-change-password/index.ts` tested
`email.isNotEmpty` — a **Dart** extension method, in TypeScript. Deno has no
such thing, so it threw a `TypeError` on the way to the password change and the
request died as a 500. Sign-in is email + password, so `email` is populated for
effectively every account and the branch always ran. A refusal shaped exactly
like a policy decision, caused by a crash. Fixed to `email !== ""`.

**Three functions nothing called.** `admin_reinstate_account` (0122),
`file_content_report` (0122) and `attach_transaction_slip` (0121) existed, were
granted, were asserted, and were reached from **no Dart file at all**. The
consequences were concrete: `content_reports` was an empty table, so the
moderation queue had no way to be filled; `slip_storage_path` is NULL on every
transaction document in existence; and `AdminContentControlScreen`'s own class
comment claimed it "suspends or reinstates an account" while containing no way
to reinstate one. All three are now wired:

- reinstate, on the moderation-history row for the suspension it reverses,
  because that is where the question "did we put them back?" is asked;
- a report action on the public provider page, which names
  `reported_provider_id` and **not** `reported_user_id` —
  `public_provider_profiles` withholds the owner's account id by design
  (20260924000006), so naming the provider is the most that screen can do, and
  asking for more would undo that hardening;
- slip attachment on each document card, uploaded under the **caller's** uid
  because the storage policy and `attach_transaction_slip` both require
  `<caller uid>/...`, and an administrator is not the customer.

**A fourth, found by reading `flutter analyze` warnings.** An appeal could be
resolved but never annotated: the buttons called `_updateStatus` straight
through, so `appeal_cases.resolution_note` was unwritable, while
`_resolveWithNote` — the helper that asks for the note — sat unreferenced in the
same file. The note dialog now runs on the screen rather than the sheet, because
the sheet is the bottom-most surface and cannot open a dialog above itself
without the dialog inheriting its barrier. Analyzer warnings dropped 20 → 18;
the two remaining are dead *duplicates* of working helpers
(`admin_history_screen._pickDate` beside `_pickDateFromSheet`,
`admin_user_management_screen._getSignedUrl` beside an inline equivalent), left
in place because neither is a broken section.

**0124 — the answer, not the guess.** `admin_rpc_signature_report()` reads the
**live catalog** for fifteen admin RPCs and compares each one against what the
Dart sends. A static check cannot settle this: the Dart, the migration text and
the deployed catalog are three things that can disagree, and only the catalog is
what the server will accept. Four failure modes, each proven by making it
happen against a scratch database:

| Injected fault | Reported |
| --- | --- |
| `p_booking_base_fare` for `p_booking_base_fee` | `client sends parameter names the function does not declare (PGRST202)` |
| `REVOKE EXECUTE … FROM authenticated` | `exists, but authenticated may not EXECUTE it` |
| function dropped | `MISSING or wrong arity` |
| a second overload of the same name | `AMBIGUOUS: 2 overloads … (PGRST203)` |

The overload row was a **blind spot the first version had**, and it is worth
recording because the assertion looked green while it was there. `to_regprocedure`
finds the expected signature, that signature is granted, its names match — every
test passes — and PostgREST still answers `PGRST203` for the call because it
cannot choose between two candidates. The expected signature being *present* is
not evidence that the call *resolves*. Overloads are easy to create by accident
in this schema precisely because these migrations restate functions with
`CREATE OR REPLACE`, and an arity change **adds** an overload rather than
replacing one.

The first negative control attempted here was itself wrong and said so: replacing
the function with a three-argument version left the fifteen-argument one in
place, because `CREATE OR REPLACE` only replaces a matching signature. The
control had to drop the function first. A control that cannot fail is worse than
no control.

`tools/harness/falsify_admin_rpc_argv.py` holds eight cases for the static half,
one of which reproduces the shipped `p_booking_base_fare` defect exactly. Two
of the eight were red on their first run for defects in the falsifier itself.

### 7.1.7 The permission that granted nothing, and the queue behind it

A second audit: "the document verification page is not there at the admin
portal, there are too many missing buttons in the sidebar, most of them have
bottom overflow, and others are dead."

**The missing page was real, and so was the reason it was missing.**
`review_user_document()` has existed since 20260927000030 — admin-only
server-side, writes an audit row, notifies the account, idempotent on a double
tap. It was reachable from exactly one place: a dialog inside one user row on
`AdminUserManagementScreen`. So working the queue meant already knowing whose
document to open, and the user list is paginated by name. The question an
administrator actually opens the portal with — *whose documents am I waiting
on?* — had no answer, and `SUSPECTED_FRAUD`, the one time-critical state, was
the hardest to reach of all.

**And the permission behind it was dead.** `staff_jobs` has carried
`document_verification` since 20260927000034, labelled *"Review identity
documents and record a verified or rejected decision"*, listed in the admin
staff screen's own checklist. No Dart file gated anything on it. A CEO could
assign it and the assignee would see no difference whatever, because the route
to the RPC sat behind `registrations` instead. **Two keys for one action, and
the specific one connected to nothing** — which is why the missing page was not
an oversight but a wiring gap.

`AdminDocumentVerificationScreen` closes both ends: the queue, and a sidebar
card gated on the key that was already being handed out. The same audit found
`category_management` was grantable and ungated too; the Category & City Fees
card now honours it **OR**ed with `isAdmin`, so staff who hold it gain access
and no admin loses any. That OR is deliberate: replacing `isAdmin` would have
been the tidier-looking edit and would have taken the section away from the
accounts that use it today.

**`view_auth_logs` is a real gap and is deliberately left alone.** It is
grantable, offered in the checklist, and there is **no auth-event table
anywhere in the schema** — no sign-in log, no failed-attempt counter, no
session table. `admin_history_screen` reads `audit_logs`, whose action types are
all administrative acts and contain nothing about a sign-in. So there is nothing
for the permission to reveal, and gating a screen on it today would produce
exactly the failure this check exists to catch: a card that opens to an empty
list. It is on a reasoned allowlist in
`check_grantable_permissions_open_something()` rather than deleted, because
deleting it would remove a promise the CEO interface already shows. **It needs
a data source before it needs a screen.**

**The first version of that check reported 63 dead permissions**, every one of
them false: fee names, category slugs, trigger names, `GRANT` roles. It scanned
every `('x', 'y', …)` tuple across 220 migrations instead of the `staff_jobs`
INSERTs. A check that reports everything is as useless as one that reports
nothing, and it would have been deleted on first sight — which is how the real
`document_verification` finding would have been thrown away with it. The
narrowing is now part of what the check claims, and case C of
`falsify_grantable_permission.py` exists only to keep it narrow.

**Overflow.** The harness cannot lay out a screen: every admin screen reads
`Supabase.instance` in `_load`, so pumping one without credentials renders the
error state and proves nothing about its content. What it can do is test a row.
`DocumentReviewCard` is therefore public and data-free — plain strings and a
thumbnail slot — following `IncomeFilterChips` in the income screen, which was
extracted for the same reason after the filter row put a striped banner under
it. `test/document_review_card_overflow_test.dart` pumps it at **320×480 across
1.0, 1.3, 1.8 and 2.0 text scale** (Android's "Large" is 1.3× and its maximum
is 2.0×), for all five document statuses, with a 70-character account name, and
**the pump is the guard**: a RenderFlex overflow is a FlutterError, so there is
nothing to assert.

Two mutations prove it can fail. Reverting the action row from `Wrap` to `Row`
gives 24 overflow reports; removing `Flexible` from the status pill and the
ellipsis from the account name gives 12 — and those only from scale 1.3
upward, which is what shows the test is genuinely scale-sensitive rather than
merely width-sensitive.

One genuine at-risk row was found by reading rather than guessing: two
`ChoiceChip`s in a plain `Row` on the staff assignment screen. Short enough at
the default scale, not at 2.0×. Now a `Wrap`, which changes no behaviour.

**What the audit did NOT find**, recorded because a clean result is a result:
every sidebar-able `/admin` route is linked from the dashboard; there is not one
`onPressed: null` literal in `lib/features/admin/`; `/admin-notifications` looks
orphaned from the admin side but is reached from three user and provider
dashboards; and both appeal types (`GENERAL`, `PASSWORD_RESET`) are handled.

### 7.1.8 PGRST202 is not a missing record, and never was

A third audit, opening with "when user try to order ride its saying that
function may have be removed" and "1st of user is not supposed to see error txt
like this".

**First, the removal claim.** `git log --diff-filter=D --name-only --all` is
**empty for the entire repository history**: no file has ever been deleted.
Across the five commits that produced the previous two audits, exactly **14
lines** were removed from `lib/`, and every one is accounted for — the
`_canEdit` reorder, the `onStatus`→`onResolve` swap, the
`p_booking_base_fare`→`_fee` fix, the `isAdmin ||` guard, and one `Row`→`Wrap`.
The ride flow, the "where" button, the GPS pulse and the availability flow were
never removed. Checking this took two minutes and should have been the first
thing done.

**The real defect, and it is the same one as §7.1.6.** `PGRST202` and `PGRST203`
mean PostgREST could not **resolve the call** — a misspelt parameter, a GRANT
naming a signature the function does not have, a migration that never ran, or
an overload it cannot choose between. Every cause is on our side of the wire.
Neither mappers had them in the missing-record branch:

- `friendly_error.dart` said *"That item could not be found. It may have been
  removed."* — the sentence that made the fee editor's typo read as a deleted
  category, and that a rider would read for a ride that was never created;
- `isNotFound()` returned **true**, so detail screens rendered their not-found
  state — a "not found" page for a ride that did not exist because the request
  never got as far as asking;
- `failure_mapper.dart` did the same in two places.

All four sites now say what is actually true, and `PGRST116` and `404` keep
saying "may have been removed" — a fix that stopped reporting missing records
would be a regression in the other direction, so
`test/pgrst202_is_not_a_missing_record_test.dart` pins both directions and
proves it goes red by re-absorbing `PGRST202` into `isNotFound()`.

**0125 — the same instrument aimed at the customer's path.** 0124 asks whether
every **admin** write path is callable. The ride failure is a **customer**
failure, so 0125 reports thirteen ride and order RPCs against the live catalog.
`create_ride_request` was checked by hand first: its eight parameter names match
the Dart exactly and 0114 grants it to `authenticated`. So either the live
catalog differs from every migration, or the failure is upstream of that
function — and only the catalog can say which. Four faults are proven to turn it
red: a missing GRANT, a drifted parameter name, an overload, and a dropped
function. Green on a clean database with all thirteen present.

Two of those controls were wrong before they were right, and both are worth
recording:

- The **GRANT** control revoked a direct grant from `authenticated` and the
  report stayed **green**. That was correct, not broken: PostgreSQL grants
  EXECUTE to `PUBLIC` by default, `PUBLIC` includes `authenticated`, and
  PostgREST switches to that role — so the call really does work. The realistic
  fault also removes the `PUBLIC` default, which is what every migration here
  does. The first control was testing nothing.
- Each `psql -c` is its **own transaction**, so a `BEGIN;` in one `-c` is
  discarded before the next runs and three controls silently "passed". They had
  to be single scripts.

**The check caught its own author twice.** `platform_transaction_fee_for` was
transcribed as three arguments and is four; `get_order_delivery_location`,
`set_order_delivery_location` and `release_order_contact` were given a
`p_actor` that does not exist and takes one, three and one arguments. Both
mistakes are the exact rot 0124 was written about, and
`check_customer_rpc_argv_is_transcribed` found them by noticing the call sites
send keys the transcription does not declare. That check also had to learn three
shapes it could not see: a call split across **comment lines**
(`calculate_fare_estimate()` inside a comment broke the anchor four lines
before the real call), an **Edge Function** written in TypeScript with **unquoted
object keys** and no `params:` key (`create_order_secure`), and parameters the
client legitimately **omits** because the function defaults them — so the rule
is "no undeclared key, and no omitted required argument", not equality.

**Availability is not missing.** It exists, and it is wired end to end: the
provider product form toggle writes `products.requires_availability_confirmation`,
the checkout swaps the payment screenshot for the availability notice, and the
provider confirms or refuses in the order detail. It **defaults to false**, so it
is off for every product unless a provider opts in — which is why a buyer never
sees it. Not a wiring gap; a default.

**The "where" button and the GPS pulse are not missing either.** "Use current
location", "Pick on map", the new "Where to?" picker (§7.1.9) and the map-picker
recenter FAB are all present, and the pulse is a `Ticker` created in `initState`
— which is the correct place, and the thing that was wrong in §7.1.5. Both
depend on a resolved GPS fix, so with location denied there is nothing to show.
Which screen is not showing them was not established here, and guessing at it
would be the wrong move.

### 7.1.9 The "Where to?" picker, and what a ListTile will not tell you

`lib/core/widgets/where_to_picker.dart` is a full-screen destination picker
opened from the ride-request screen by a **"Where to?"** `TextButton.icon` in
the Destination row, beside "Pick on map". Both routes end at the same place:
`_openWhereTo()` feeds the result into `_selectDestSuggestion(picked)`, so the
fare re-quotes through exactly the code path a map pin takes. Two entry points
to one destination, not two destinations.

What it does:

- **A search bar** over `GeocodingService.instance.searchPlaces(query,
  biasPoint:, limit: 8)` on a 320ms debounce, with a `_searchGeneration`
  counter so a slow response for "Bole" cannot overwrite a fast one for
  "Bole Lemi".
- **Nearby areas** from `GeocodingService.instance.nearbyAreas(at)` —
  kebeles via Overpass (`place=…|admin_level=9|10`), shown in their own group
  above the search results, so a rider with no landmark in mind still has
  something to tap.
- **A map** (`FlutterMap` + OSM tiles, `userAgentPackageName:
  'app.aliob.birr5'`) with a `CircleLayer` halo and a `MarkerLayer`. The halo
  is a fixed 60m because `LocationResult` carries **no accuracy** — inventing
  an accuracy figure the service did not report would draw a confident circle
  the app cannot justify.
- **A fixed 48x48 round action** beside the field that swaps a spinner for a
  crosshair icon, and calls `LocationService.instance
  .getCurrentPositionDetailed()`.
- **A confirm button that is disabled but visible** when nothing is chosen:
  "Pick a place to continue". Hiding it would read as a broken app; a greyed
  button that explains itself does not.
- **One pulse**, driven by a `Ticker` created in `initState` and disposed with
  the state — the same rule §7.1.5 got wrong.

#### The measurement that came out wrong

`test/where_to_picker_overflow_test.dart` was first written to assert that
these rows do not overflow, with the labels capped at one line. **Deleting
every `maxLines: 1` left all nineteen tests green.** The file claimed to guard
something it was not guarding.

The reason is worth writing down, because it is not specific to this widget:

> A `ListTile` bounds its own height. Its title is laid out with a max height,
> so a label that does not fit **clips** — the row never grows, and
> `tester.getSize` on the label reports one line's height whether `maxLines` is
> set or not.

Measured directly, crossing `dense` true/false with `maxLines` set/unset on
the *longest label OpenStreetMap actually returns*:

| `dense` | `maxLines` | short label | long label |
|---|---|---|---|
| `true` | `1` | 64dp | 64dp |
| `true` | none | 64dp | 64dp |
| `false` | `1` | 72dp | 72dp |
| `false` | none | 72dp | 72dp |

Row height is a function of `dense` **alone**. The label's length is not
visible to layout at all. Any assertion of the form "the row is under N line
heights" was reading a constant.

The same probe killed the parallel claim for the confirm button: a `FilledButton`
has no height bound of its own, but it did not grow either, so its height
assertion was equally vacuous.

So the promise is now guarded **where it is actually made — on the widget**:

- `ListTile.dense` is asserted directly on every result tile. This is real: it
  goes red on `dense: true` → `dense: false`, and it is worth asserting, because
  `dense` is what makes the row 64dp instead of 72dp and therefore what fits
  more results above the confirm button.
- `Text.maxLines == 1` **and** `Text.overflow == TextOverflow.ellipsis` are
  asserted on the title, the subtitle and the confirm label. The ellipsis is
  the point, not the decoration: without the cap a ListTile chops a place name
  at an arbitrary pixel and the user is given nothing to show it was cut; with
  it, the truncation is visible.
- The search row is asserted by **pumping**, not by measuring: a `Row` whose
  children exceed its width raises a `RenderFlex` overflow in a widget test, so
  those eight cases are a genuine guard at 320x480 across every text scale
  Android offers. Both states are pumped, because the action button swaps a
  48dp spinner for a 20dp icon on every GPS fix and the field beside it must
  not shift when it does.

All four assertions were then **proven red** by mutation — `dense: true` →
`dense: false`, and `maxLines`/`ellipsis` deleted from the title and from the
confirm label — and restored. 19 tests.

The `Where to?` button was verified to be **unconditional**: it is not behind a
flag, a feature gate or a role check, so there is no configuration in which a
rider cannot reach it.

### 7.1.10 The fee editor had never once worked

Four reports, and only one of them turned out to be what it looked like.

#### The fee editor: found by running it, not by reading it

`admin_save_category_fee()` had **never saved a single row**, since the day
0107 created it. Replayed against a real PostgreSQL 14
(`sh tools/harness/replay_fee.sh`), every call died with:

```
42703: column "booking_base_fare" of relation "category_fee_settings"
       does not exist
```

0107 renamed the column `booking_base_fare` → `booking_base_fee` when it
renamed the matching argument `p_booking_base_fare` → `p_booking_base_fee`. The
INSERT column list was updated. Every resolver was updated. The
`ON CONFLICT ... DO UPDATE SET` list was not:

```sql
ON CONFLICT (category_id, city) DO UPDATE SET
  ...
  booking_base_fare = EXCLUDED.booking_base_fee,   -- no such column
```

**PostgreSQL analyses `INSERT ... ON CONFLICT DO UPDATE` before it executes
it.** So this is a plan-time failure: no row, no audit row, no trace.

#### Why every existing check was green

This is the part worth keeping. Each existing check answered a *different*
question, and answered it correctly:

| Check | Question | Answer |
|---|---|---|
| Migration 0124 | does `admin_save_category_fee` exist with the arity and parameter names the client sends? | **yes** — it always did |
| `check_admin_rpc_argv_is_transcribed` | does the Dart send any undeclared parameter? | **no** — the mistake is in the function's *body* |
| `check_category_fees_are_wired` | is every fee field group both rendered and sent? | **yes** |
| `assert_category_fees_are_wired` | are the money columns nullable so blank means "inherit"? | **yes** |

All four describe the **call**. None of them executes the **statement**. A
correctly named, correctly granted, correctly called function can still be
unable to run — and "is it wired" and "does it work" are different questions,
and only one was being asked.

#### The two answers it now gives

- **Harness gate 6**, `tools/harness/conflict_targets.py`: collects every
  table's columns from every `CREATE TABLE` **and every `ALTER TABLE ... ADD
  COLUMN`**, then checks every `ON CONFLICT ... DO UPDATE SET` target against
  the table it updates. A restatement supersedes, because the live database
  holds the last definition — otherwise this gate would be permanently red
  over a deployed migration that can never be edited, and a gate that is always
  red is a gate nobody reads.
- **`assert_category_fee_save_plans()`**, run by Connectivity CI: `EXPLAIN`s
  the upsert without `ANALYZE`, which **plans without executing**. A column
  that does not exist fails at plan time, so this needs no rows, no category
  and no fee-editor authority.

The two cannot see each other: SQL cannot read the Dart, and Python cannot
plan a statement.

Its falsifier (`falsify_conflict_targets.py`) includes the case that matters
most — 0107's broken body with the 0126 restatement removed, which is the
*exact* state of the live database before this fix. The check is red there.

That check earned its keep immediately, twice: it caught a genuine defect in
the new 0126 assertion itself (twelve `NULL`s written for thirteen columns),
and it refused to go green until told that a later restatement supersedes an
earlier broken body.

#### The sentence the user saw, and why it was wrong twice

`friendly_error.dart` reported this 42703 as **"That item could not be found.
It may have been removed."** — because the branch matched `'does not exist'`,
which in a query's error names a **schema object on our side**, never a
customer record of theirs.

`'does not exist'` is now gone from **both** `friendlyError()` and
`isNotFound()`. Removing it from only one would have left every detail screen
rendering its "not found" state for a request that failed our side.

A correction to an earlier note in this document: `CATEGORY_NOT_FOUND` was
*also* believed to cause this, on the grounds that it contains "not found". It
does not — it is `category_not_found` with an **underscore**, and the branch
matches the substring with a **space**. An exclusion list was written on that
false premise, and its own mutation run proved the list was dead code, so it
was removed rather than kept. The 42703 was the whole cause.

14 tests pin this in both directions, and five mutations were proven red:
re-adding `'does not exist'`, dropping `'not found'`, giving the 42703 branch
the old sentence, dropping the non-owner branch, and dropping the 42703 arm.
The third of those — dropping `'not found'` — was a regression introduced while
writing the fix, caught only because a direct assertion existed for it.

#### Image moderation: a gallery that was not there

`AdminContentControlScreen` read `admin_content_reports`, which returns rows
somebody has already **reported**. A moderator looking for a specific picture
had no way to look, because most content that breaks the rules is never
reported. There was no admin function that lists gallery photos at all.

Migration 0126 adds four, each exercised in `tools/harness/replay_fee.sh` as
the right actor *and* the wrong one:

| Function | Purpose |
|---|---|
| `admin_public_image_gallery(city, limit, offset)` | every published image, with the **uploader's name, their business and their city**, across `provider_gallery`, `product_images` and `vehicle_images` |
| `admin_set_gallery_image_public(id, public, reason)` | **hide without deleting** — reversible, and the provider keeps their copy |
| `admin_warn_user(user, title, body)` | send a `CORRECTION_REQUIRED` notice from that section, written to the log whatever the delivery does |
| `set_gallery_image_public(id, public)` | the provider's own unpublish/republish |

**Hide is offered before delete, deliberately.** `admin_moderate_image`
deletes the row *and* the object, irreversibly, taking the provider's copy
with it. `is_active` already exists and already gates
`provider_gallery_public_read`, so hiding is a one-column write the policy
already honours. The reported need was "delete **or** suspend it from the
public" — the second is the one to reach for by default.

Restoring demands a reason: putting a photo back after a takedown overrides an
earlier decision and the record should say why.

### 7.1.11 A provider's photo is public the moment it uploads

Reported as "after uploading there is no post option to public and it's not
moving to public". Two facts read from the schema rather than assumed:

- `add_gallery_image` inserts `is_active = true`. **An upload is public the
  moment it lands.** Nothing is hidden.
- `provider_gallery_public_read` requires `is_active = true` **and** the
  provider's status `APPROVED`.

So "it's not moving to public" is not a missing toggle — it is a photo
belonging to an account that is not approved yet, or one an administrator has
suspended. Inventing a "post" switch would have flipped a flag that is already
on, and reported success while changing nothing.

The honest fix is to **show** that, and to give the owner a real control.
`set_gallery_image_public` lets a provider unpublish and republish their own
photo, and its reply says plainly which of the two states they are in:

```
Photo published. It is now visible on your public profile.
Photo published, but still not visible to customers: your account is
pending approval. It appears once your account is approved.
```

`gallery_visibility_report()` exists so that "why is my photo not showing" has
an answer read from the database rather than guessed at in a support thread. It
reports all three numbers — total, active, and actually visible — because the
gap between the last two **is** the answer.

### 7.1.12 "Where to?" on the map, and a button that was not on screen

Two reports, two causes.

**The map had its own copy of the search.** `live_map_screen.dart` opened a
private `_DestinationSearchSheet` — a second implementation of the same idea,
living only there. It had **no nearby-areas list** and no GPS action, which is
exactly "the where button is on the request page but not on the map". Both
surfaces now open the same `WhereToPicker`; the duplicate is deleted.

**"It stacks and does not proceed."** The picker's keyboard inset was a
`SizedBox(height: viewInsets.bottom)` placed *between the map and the list*,
**inside** a column the caller had already bounded to 0.94 of the screen. That
adds up to ~300dp of content on top of a layout whose fixed children (grabber
+ search bar + a 210dp map) already used most of it, so the `Flexible` list
received **zero** height — and because `_confirmButton()` was built *inside*
`_list()`, the **"Go to …" control went with it**.

Nothing was stacked. The primary action was squeezed off the screen. The inset
now pads the sheet from **outside**, the map drops to 120dp while the keyboard
is up, and the confirm button is a direct child of the column rather than a
descendant of the scrollable list.

### 7.1.13 The gallery nobody could see, and the document nobody was told about

Two reports, and both turned out to be "the thing exists and nothing reaches
it".

#### A gallery with no page to be seen on

"I tried the photo upload section with both verified, and wallet charged
provider but still the posting page and the price attaching with it is missing
on gallery after uploading the image 2."

`provider_gallery` was read in **exactly one place**: the provider's own
upload screen. `grep -rn provider_gallery lib/` returned the model, the
provider screen, and nothing else.

`user_provider_detail_screen.dart` — the page a customer actually sees — had a
section called "Photos". Every tile in it came from `product_images`, the
**marketplace listing imagery**. The provider's own gallery was never queried.
A provider who paid to upload photographs, whose wallet was charged, saw
nothing change anywhere a customer could look, and there was no error to
explain it: nothing failed, the query was simply never made.

Two changes:

- the page now reads `provider_gallery` through the same RLS the rest of the
  page uses (`provider_gallery_public_read`: `is_active` **and** an APPROVED
  provider), so a hidden photo is absent here for the same reason it is absent
  everywhere rather than being un-hidden by a second query that disagrees. The
  read is non-fatal: a gallery that fails to load must not take the provider's
  name, products and reviews down with it;
- `product_images` is now labelled **"Listing photos"**, so the two are not
  presented as the same thing.

**The price.** `provider_profiles.price_range` has existed since the first
schema snapshot and is projected by the public view. No screen in the app read
it and no screen let a provider set it, so it was always NULL and always
would have been. It now renders in the provider page header — **only when it is
set**, because an empty pill reads as "this provider charges nothing", which is
the opposite of what "not set" means — and it is editable in Business Profile.

#### A submitted document told nobody anything

"when people sent their documents let notifications appear both at front
dashboard and in apps notifications at the same time ... for all parties".

`DocumentUploadService.uploadAndRecord` does exactly two things: upload the
file, and `insert` a `user_documents` row. There is no third statement, and
**no trigger on `user_documents` exists anywhere in the schema**. So:

- the person who uploaded an ID was told nothing, and a silent upload is
  indistinguishable from a failed one;
- nobody holding `document_verification` was told a document arrived, so the
  review queue was filled by people who happened to go and look.

Migration 0127 adds one `AFTER INSERT` trigger and one `AFTER UPDATE`. "All
parties" means all parties: a submission is a message **to** the reviewer and
an acknowledgement **to** the submitter.

Why a trigger and not a function call: the write is a direct client `INSERT`,
from two different places, and both are on paths that must keep working when a
notification fails. There was no trigger, so every caller had to remember to
notify — and one did not. A trigger cannot be forgotten by the next caller.

`notify_user_once()` rather than `notify_user()`, because the key is derived
from the **row id**: a retried write of the same document collapses, and two
genuinely different documents each notify, because a reviewer must hear about
both.

#### The recipient set, and the two bugs the replay found in it

`document_review_recipients()` answers "who could open the review screen". Two
defects, both found by replaying the migration and **counting the rows** — the
only thing that can see either:

1. **The account owner was excluded.** The first version matched
   `'document_verification' = ANY(staff.permissions)` and then excluded anyone
   with a staff row from the `ADMIN` branch. A CEO has a staff row, so they
   matched neither branch and were told nothing — while the comment above the
   function claimed administrators were always included.
2. **The account owner got two notices for every document.** The function
   returned `(user_id, is_admin)`; a CEO who is both an `is_ceo` staff member
   and an `ADMIN` in `user_roles` produced two rows that `UNION` cannot
   collapse, because they differ in the boolean. Both notices "worked", the
   trigger did not raise, and the report said ok.

It now returns one column, and says why in the function.

#### The swallow that was too good

`notify_user_safe()` exists so a notification can never roll back the write
that triggered it. While building the fixture, `notify_user_once` was declared
with `p_type text` instead of `public.notification_type`. **An enum has no
implicit cast to text**, so every call raised — and the `EXCEPTION WHEN OTHERS
THEN RETURN false` swallowed it. The outcome was indistinguishable from "no
notifications were sent": no error, no warning, a green report.

That is what a swallow buys, and also the danger: **a notification path can be
completely dead and still report success.** So the wiring report now asserts
the exact signature of `notify_user_once` and `notify_user`, by
`to_regprocedure`. One signature the whole chain rests on, checked where a
mismatch is loud.

The same lesson shaped the trigger's shape: `notify_user_safe` has a
**top-level** `EXCEPTION`, the shape 0092 already uses, rather than a nested
`BEGIN ... EXCEPTION` block inside the trigger. The SQL-body scanner in
`plpgsql_body_syntax.py` splits on semicolons at paren depth 0 and has no idea
about plpgsql block structure, so a nested `BEGIN` reads as a bare `BEGIN`
statement followed by `PERFORM ...` — a syntax error in a trigger that is
perfectly valid. The harness is blunt rather than wrong, and matching the shape
that already passes it was the right answer, not weakening the check.

The dashboard card for Document Verification is the only actionable card that
carried no number; it now shows the pending count from
`admin_pending_document_count()`, which checks the asker's own permission
server-side rather than running a client `COUNT` that RLS does not scope for
reviewers.

`scratch/db/document_probe.sql` exercises all of it as the right actor and the
wrong one: submitter notified once, reviewer notified once, uninvolved third
party notified **zero** times, a repeated key producing one notice, a second
document producing a second notice, each of the three verdicts reaching the
person, and a non-reviewer refused the count with `ADMIN_ONLY`.

### 7.1.14 The first screen was navigation, and half the app had a different Account tab

Two reports, and both were "the thing exists, and the surface does not show
it" — the same shape as §7.1.13, in the two places every user passes through
first.

#### Home spent its first screen on navigation

The three big category cards were 120dp each, the trending providers were a
horizontal rail of 110-wide tiles (two and a half visible, no cue that more
existed) inside a fixed 200dp band, and "Top categories this week" printed
the ranking verbatim. All three were navigation, and two of them duplicated
what the page already said: the chip rail named the same three mother
categories as the cards above it, and it sat between the provider photos and
the feed instead of beside the thing it describes.

What is there now, and the number that makes it hold:

- **60dp is a minimum, not a height.** `_MainCategoryCard` uses
  `BoxConstraints(minHeight: 60)`, a 34dp icon and 13.5/10.5 type. A fixed 60
  would paint a bottom-overflow stripe at a large accessibility text scale;
  the row grows instead.
- **Four photos across, exactly.** `_gallerySection` is a `LayoutBuilder`
  computing `(maxWidth - 16*2 - 8*3) / 4`, so the same four tiles read on the
  narrowest phone and on a tablet. The label sits under the photo with the
  verified badge, and the name row is under the image rather than over it, so
  a dark photo cannot swallow the one fact the tile exists to state.
- **The rail moved and changed level.** It is directly above Fresh Finds and
  names the SMALL categories, not the mothers. `ranked_categories` cannot
  order the leaves (see §4), so `subcategoryRailOrder()` does it from the
  `ranked_categories` rows (`category_id`, `name`, `marketplace_sector`) and
  one bounded `categories(id, parent_id)` read (`limit 1000`) for every active
  leaf. The cap is 12, and an empty ranking or a failed tree read hides the
  rail rather than rendering an empty strip.

#### The data path, end to end

| Surface | Function / RPC | Table / columns | Leads to |
|---|---|---|---|
| three big cards | `CategoryGroup.membersOf()` | `categories`: `parent_id IS NULL`, `sector`, `marketplace_sector`, `sort_order`, `is_active` | `/user/category-group/:group` |
| the three card subtitles / group screen | same `CategoryGroup` rule | same row, counted by one `categories(parent_id)` read (`limit 500`) | `/user/category/:id` |
| "Top categories this week" | `ranked_categories(p_limit, p_offset)` → `subcategoryRailOrder()` | its `RETURNS TABLE` (`category_id`, `name`, `slug`, `marketplace_sector`, `provider_count`, `completed_transactions`, `rank_position`) + `categories(id, parent_id)` for leaves | `/user/category/:id` |
| Trending providers | `ranked_providers` (this week, then career totals) + `provider_trust_stats` + `visible_gallery_for_city` for the feed below | `ranked_providers`: `id`, `business_name`, `city`, `price_range`, `completed_transactions`, `rank_position`, `photo_storage_path`; `provider_trust_stats` for the verified badge | `/user/provider/:id` |
| a category page | `visible_products_for_city(p_city, p_category_id)`, `ranked_providers(p_category_id, p_limit)`, one `product_images` batch | products and provider rows above; `product_images.product_id`; bucket `provider-photos`; `ProductCard.listing` with `listingType` and `listingPriceLabel` from the listing's own row (BUY vs BOOK) | listing / provider |
| every Account tab | `AccountDashboard` (one widget) | see the table in §4 | `/wallet`, `/appeals`, `/points`, `/account/password`, `/account/deletion`, `/terms-of-service`, `/about`, `/help`, `/user/favorites`, `/user/ride-active`, `/user/ride-history`, `/map`, `/become-partner` |

`ranked_categories` itself was restated by `20261015000011` to lead with the
7-day window; `assert_category_tree_and_rank_are_wired()` reads the function
bodies back by name and fails the deploy if the window, the completion-time
comparison, the `is_admin()` check in `admin_create_category`, or the
mother-inherits-its-classification rule ever disappears. It runs at the end of
that migration and is also worth calling directly after the first deploy:
without it the rail still renders, still looks ranked, and never moves.

#### The provider dashboards had a two-row Account stub

A buyer reached `/user` → Account → `UserProfileScreen`, which rendered the
full account dashboard. A service provider or vehicle provider reached their
own dashboard's Account tab and got a `Column` with **Wallet** and **Profile**
— two rows, two routes, and no appeals, no city, no Terms, no account
deletion. The account existed; half the app could not see it.

`AccountDashboard` is now the one definition, with the contract described in
§4. The provider dashboards call it with `embedded: true` and
`padding: EdgeInsets.zero` because their tab host already owns the scroll view
and the app bar; their Business, Catalogue, Orders, Vehicles and Shop tabs are
unchanged. The buyer's `UserProfileScreen` is now the same call with no
arguments.

The dashboard reads only what it renders: `authProvider` (profile name, phone,
email, status; `isProvider` for the Become a Partner row), `PointsService`
(`user_points`), `cityProvider.updateSavedCity()` (`profiles.city`), and —
through the `VerificationStatusTile` it embeds — the caller's `user_documents`
review state via `ProviderDocGate.reviewState`, which is the VERIFIED/REJECTED
state rather than the generous "may work" `DocCheckStatus`. Every row is a
`context.push` to a route that already existed — no new table, no new column
and no new RPC were added for this pass.

#### The category screens now share the home's type and rules

The buyer category screen was rebuilt on the same section style as Home
(`_sectionTitle`) and its provider rows now carry the four facts the other two
provider lists already read from the same `ranked_providers` row — photo
(`photo_storage_path`, bucket `provider-photos`), `price_range`,
`completed_transactions`, `rank_position` — so the same business cannot be
described differently on Home, in "All providers" and here. The group screen's
rows use `categoryIconForSector()` instead of one generic glyph for every row;
that is the same function the home rail's chips use, and it is the whole
reason the rule lives in `lib/core/utils/category_icons.dart` rather than in
either screen.

#### Verification

`flutter analyze --no-pub`: 0 errors, issues at the pre-change baseline.
`flutter test`: 479 passed, including `test/home_subcategory_rail_test.dart`
(ordering, mixing, unknown mothers, cap, empty, and no-repeat-past-the-cap).
`tools/harness/run_all.sh`: 71 checks, exit 0. The layout itself was verified
by static analysis and tests only — this workspace has no emulator, so no
screenshot was rendered.

### 7.2 Edge Functions

Deployed by the `Deploy function …` steps in `.github/workflows/deploy-supabase.yml`.
Every one of these is called from Flutter:

```
repo-chat  index-chunks (--no-verify-jwt)  provider-approval  admin-wallet-recharge
wallet-deduct-fee  subscription-process  order-create  order-transition
ride-claim  ride-transition  document-verify  user-admin  send-otp
staff-create-gateway  staff-delete-gateway  staff-change-password
staff-login (--no-verify-jwt)  login-gate (--no-verify-jwt)
account-change-password  account-deletion-gateway
```

Three notes that are easy to get wrong:

- A function present in `supabase/functions/` is **not** deployed unless the
  workflow has a step for it. That is how "Change password" and "approve
  account deletion" shipped broken (§5.6).
- **A pre-authentication endpoint must be deployed with `--no-verify-jwt`.**
  The gateway refuses an anonymous request to a function deployed with the
  default `verify_jwt=true`, with a bare 401 before the function body runs.
  Three functions are pre-auth by construction — `login-gate`, `staff-login`,
  `index-chunks` — because the caller has no session yet. `login-gate` shipped
  without the flag while its own header said it "must run BEFORE the credential
  check is even attempted", so the gate never executed and no login in the app
  could complete. Being reachable is not the same as being usable, and the
  symptom (a generic "sign-in unavailable") pointed nowhere near the cause.
  `PRE_AUTH_FUNCTIONS` in `tools/harness/static_checks.py` now fails the build
  if one of them loses the flag.
- `send-otp` additionally needs an email provider configured in
  Supabase → Edge Functions → `send-otp → Secrets`. **Resend**:
  `RESEND_API_KEY` + `OTP_FROM_EMAIL`. **Brevo** (free tier, no card):
  `BREVO_API_KEY` + `BREVO_FROM_EMAIL`. Resend is tried first; with neither
  pair set the function returns `email_provider_not_configured` and **no
  registration email is ever sent**.

### 7.3 Secrets

| Key | Where | Consequence if missing |
|-----|-------|------------------------|
| `RESEND_API_KEY` | Supabase edge-function secret | no OTP email |
| `OTP_FROM_EMAIL` | Supabase edge-function secret | no OTP email |
| `INDEXER_KEY`, `INDEXER_URL` | GitHub Actions + Supabase | help chat cannot index or answer |
| `LLM_PROVIDER` | Supabase (`none` is the only supported mode) | — |

`supabase secrets set` in the deploy workflow only ever writes `INDEXER_KEY`
and `LLM_PROVIDER`; it upserts and does not delete, so anything set by hand in
the dashboard survives a deploy.

### 7.4 Supabase Auth configuration

- **Email confirmation must stay disabled.** Registration relies on
  `signUp()` returning a session immediately; the approval gate is
  `profiles.status = PENDING_APPROVAL`, not a confirmation email.
- Google OAuth must stay enabled if the app's Google button is advertised.

### 7.5 After a deploy

1. Connectivity CI green (85 tests). If it is red, the failure message names
   the assertion — read the `Diagnostic:` line before changing anything.
2. Flutter CI green.
3. `select public.assert_signup_otp_toggle_is_consistent();` returns a string,
   not an exception.
4. `select public.assert_document_liveness_is_recorded();` returns a string.
5. `select public.assert_live_map_is_wired();` returns a string.
6. `select public.assert_gated_buyer_payment_request_is_wired();` returns a
   string.
7. `select public.assert_notify_user_once_is_idempotent();` returns a string.
   This one is a **write** test that rolls itself back; run it once after the
   first deploy of `0086`, because it is the only place the dedupe and the
   failure isolation are actually exercised rather than inspected.
8. `select public.assert_approval_welcome_covers_all_paths();`,
   `assert_order_and_ride_receipts_are_sent();`,
   `assert_points_conversion_notifies();`,
   `assert_notification_inbox_is_owner_only();` and
   `assert_every_assertion_is_reachable();` each return a string beginning
   `ok:`. A `FAIL:` prefix names the specific thing that regressed.
9. `select public.assert_source_needles_match();` returns `ok:` — the
   source-matching assertions are comparing against text that exists.
10. `select public.assert_app_buckets_exist();` returns `ok:` and names all
   six buckets. A `FAIL:` prefix names the bucket that is missing or has the
   wrong visibility: `product-images` / `provider-gallery` / `vehicle-images`
   have to be there and public, `user-documents` / `payment-proofs` /
   `payment-screenshots` have to stay private. This is the only check that can
   see a missing bucket — the policy-shape assertion next to it reads
   `pg_policies`, where a bucket with no policies and a bucket that does not
   exist look identical.
11. `select public.assert_activation_fee_writes_income();` returns `true`.
   This is a **write** test that rolls itself back, and it is the only place the
   activation-fee withholding branch is exercised rather than inspected: it
   drives `approve_wallet_recharge` for a provider whose
   `registration_fee_paid` is false and asserts the fee lands as `platform_fee`
   on the `RECHARGE` row. Run it once after the first deploy of `0098`.
   `select public.assert_income_covers_every_fee_type();` returns a string
   beginning `ok:` that prints every fee figure — a `FAIL:` prefix means the
   ledger's arithmetic is impossible or a recharge withheld money without
   recording it as a fee.
12. `select public.assert_category_tree_and_rank_are_wired();` returns `true`
    (or a string naming the regression). Run it once after the first deploy of
    `20261015000011`: it is the only check that reads the *body* of
    `ranked_categories`, so it is what notices a restatement that quietly
    reverts the rail to career totals.
13. **Update `supabase/DEPLOYED_HEAD`** to the last migration the log reported as
    `Applying migration <name>`, and commit it. This file is the only thing in the
    repository that knows which migrations the live database has, and it is what
    makes `sh build/run_all.sh` check the right window (§7.1.1). Skipping it does
    not fail the build — the gates stay green over a window that has quietly
    stopped covering the pending migrations — which is exactly why it is the last
    step of a checklist rather than a step in a script.

    A deploy that logs `Staged N migration files` and then `Remote database is up
    to date` applied **nothing**: leave the marker where it is. "The workflow went
    green" and "the migrations were applied" are different facts, and only the
    second one moves this file.

**Migrations must be applied before Connectivity CI can pass.** It runs against
the live database, and it runs as the **`anon`** role: the suite builds
`SupabaseClient(_url, _anonKey)` with no session. An assertion granted to
`authenticated` only, and revoked from `anon`, is invisible to it — and
PostgREST reports that as `PGRST202 "could not find the function in the schema
cache"`, which reads like a missing migration and sends you to the wrong file.
Five new assertions failed exactly that way after a clean deploy; migration 91
fixes them and `assert_every_assertion_is_reachable()` now checks the whole
`assert_*` family so the next one fails by name. A `GRANT` to `authenticated` on
its own is harmless — anon inherits EXECUTE-for-PUBLIC — and it is the
`REVOKE ... FROM anon` that removes the suite's only path.

**Nothing can log in until `login-gate` is redeployed with `--no-verify-jwt`**
(§7.2). The flag is in `deploy-supabase.yml`, so any run of the Deploy Supabase
workflow picks it up — but no migration can fix it, because the failure is at
the gateway, before the function body. A build shipped against the old
configuration cannot sign in *anyone* in, and the app says "sign-in is
temporarily unavailable", which names neither the function nor the flag.
