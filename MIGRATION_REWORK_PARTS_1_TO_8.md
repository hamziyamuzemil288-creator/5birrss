Parts 1–8 of the registration and checkout rework, as one release commit.

Migrations (six new, all idempotent / SECURITY DEFINER where appropriate):
  • 20261014000000 — self-service registration is immediately active.
    handle_new_user creates APPROVED profiles for every self-signup; no admin
    gate for users, and a staff referral code is the only thing that keeps a
    staff-assisted provider PENDING until documents are reviewed. Auto-approved
    activation also goes to the top of the availability queue so availability
    and payment are answered in the right order.
  • 20261014000001 — document verification is voluntary for service providers:
    remove the DOCUMENTS_UNVERIFIED blocker from provider_fulfilment_blockers(),
    scoped back to VEHICLE_PROVIDERs only so the bike-share app's driver docs
    rule stays alive.
  • 20261014000002 — display_price is the ONE public price: a generated
    products.display_price (provider price + 5 + 1.9%), read by Product, the
    shared card, the cart and search_products instead of the raw price.
  • 20261014000003 — the platform's contact number and payment account, as
    data: a whitelisted public_app_settings() RPC the buyer can read, seeded
    empty so the client cards have stated fallbacks (help chat / Payment
    Methods). Also lifts the system_settings guard trigger around the seeds
    (the 0113 class of failure).
  • 20261014000004 — admin can answer availability requests too: the same
    respond_availability_request RPC now accepts administrators, with the
    first-to-answer wins / one answer ever guard replicating the provider path.
  • 20261014000005 — staff registration oversight: staff_registration_stats()
    rounds up providers_registered and products_posted per staff member, read
    back in the admin staff performance dialog.

Supabase function (order-create):
  • create_order_secure reads display_price instead of price, so the order
    records what the buyer saw on the card and checkout.

lib:
  • lib/core/models/product.dart — publicPrice, formattedDisplayPrice /
    displayPrice (Part 2); hasPhoto the text-only branch (Part 5).
  • lib/core/services/cart_service.dart — reads display_price, carries
    listing_type (Part 2).
  • lib/core/services/platform_settings_service.dart — the buyer-safe loader
    for public_app_settings (Part 3/4).
  • lib/core/widgets/product_card.dart — Part 7 BoxFit.contain fix on the
    single shared card, so photo-less listings render as text-only cards and
    every Discover surface changes together.
  • lib/core/widgets/admin_payment_details_card.dart — the buyer pays the
    platform's account, not a provider's (Part 4).
  • lib/core/widgets/platform_contact_card.dart — the buyer's "call a human"
    door points at the platform (Part 3).
  • lib/core/widgets/system_banner.dart — the persistent system banner
    mounted above the navigator (Part 8).
  • lib/app.dart — SystemBanner on top of MaterialApp.builder.
  • lib/routing/app_router.dart — /provider/documents, /admin/platform-settings
    (with initialSection), and ?assisted=1 on the signup route (Part 6).
  • lib/features/auth/signup_screen.dart — always-on captcha, privacy checkbox
    (reads the policy page), welcome banner, direct dashboard navigation, and
    the staff-assisted walk into /provider/documents.
  • lib/features/admin/admin_platform_settings_screen.dart — Contact Settings /
    Payment Settings as one screen with two doors.
  • lib/features/admin/admin_availability_screen.dart — Approve / Decline on
    PENDING rows, with the listing's cover photo.
  • lib/features/admin/admin_dashboard.dart — Contact Settings + Payment Settings
    cards beside System Settings.
  • lib/features/admin/admin_staff_screen.dart — staff_registration_stats rows
    in the performance dialog.
  • lib/features/provider/provider_documents_screen.dart — the voluntary
    "Verify Documents" screen a provider's Settings points at (and the first
    stop after a staff-assisted signup).
  • lib/features/provider/service_provider_dashboard.dart — "Verify Documents"
    badge, the pending-availability card with the listing cover photo.
  • lib/features/user/user_order_detail_screen.dart — AdminPaymentDetailsCard
    in the payment step, plus the buyer's platform-contact card.
  • lib/features/user/user_checkout_screen.dart — pays AdminPaymentDetailsCard.
  • lib/features/user/user_product_detail_screen.dart — price reads publicPrice.
  • lib/features/staff/staff_dashboard_screen.dart — "Register a provider" door
    that pushes /signup/service?assisted=1 after stating the trade-off.

Harness:
  • tools/harness/static_checks.py — update the signup OTP/captcha check and
    the checkout payment check to the new wiring; add a wiring check that every
    part's server half and every part's client door still talk to each other.

═══════════════════════════════════════════════════════════════════════════
Parts 9–11 (added to the same release; one commit, one CI trigger)
═══════════════════════════════════════════════════════════════════════════

Migrations (three new, idempotent / SECURITY DEFINER where appropriate):
  • 20261015000001 — every notification also leaves as a push, from ONE place.
    9a: an AFTER INSERT trigger on `notifications`
    (trg_notifications_push_dispatch) writes one n8n push event per
    notification for every recipient that has an active device token, through
    the EXISTING dispatcher create_n8n_event(). It honours
    notification_preferences.push_enabled, stays silent for an account with no
    token, and skips the app-release broadcast, which batches its own event.
    No second pathway: the push still rides `n8n_events`, and no caller can
    produce the in-app row without the push because the point is the table,
    not a call site. Also asserts the availability wait is SERVER state
    (assert_availability_wait_is_server_state).
    9b needed no migration: availability_requests is already buyer-readable,
    already published for realtime, and already resumed-not-duplicated by
    create_availability_requests — the assertion pins all three.
  • 20261015000002 — the delivery fee IS the ride fare. platform_display_markup()
    is now the ONE definition of the markup (amount + 5 + amount * 0.019) and
    products.display_price is GENERATED from it, so the product price and the
    delivery fee cannot drift. calculate_delivery_fee_at() prices through
    calculate_fare_estimate_at() — the reader create_ride_request charges a
    ride with. quote_delivery_fee(provider, buyer point, vehicle category,
    city) is the single callable the checkout quotes with AND order-create
    prices with; it resolves the provider's own point (which a buyer may not
    read) and returns ok=false with a reason rather than inventing a fee.
    assert_delivery_fee_reuses_the_ride_fare() reads the deployed bodies and
    the column expression to prove all four still resolve through the same two
    functions.
  • 20261015000003 — a provider can hide a listing and can only really delete
    one nothing references. provider_delete_product() counts order_items and
    deletes when there are none, hides (is_active = false) when there are, and
    says which happened; provider_set_product_visibility() writes the SAME
    is_active flag every public read already filters. The unskippable guard is
    the existing order_items -> products foreign key (confdeltype 'a', NO
    ACTION), asserted by assert_order_history_blocks_a_hard_delete();
    assert_hidden_listings_leave_every_public_surface() pins the one flag on
    products_public_read, visible_products_for_city, search_products and
    product_trending.

Supabase function (order-create):
  • accepts delivery_lat / delivery_lng / vehicle_category_id — pricing INPUTS,
    never a fee — and prices the trip with quote_delivery_fee, the same RPC the
    checkout quoted with. The fee goes into the order total and onto the order
    note. When the server cannot price the delivery it charges the product
    price and logs why, instead of charging an invented number.

lib:
  • lib/core/services/fee_resolver.dart — DeliveryQuote + deliveryFee(), and
    'order-create (delivery fee)' -> 'quote_delivery_fee' in
    chargePathResolvers.
  • lib/features/user/user_checkout_screen.dart — the delivery option now runs
    vehicle -> location -> map (WhereToPicker, the existing map page), quotes
    the fee from the server, shows product price + delivery fee = total, and
    lets the buyer change vehicle, move the point, or remove delivery with the
    total following, all without leaving checkout.
  • lib/features/user/pending_availability_section.dart — new: the buyer's
    availability requests with live status, on the Orders screen.
  • lib/features/user/user_orders_screen.dart — mounts it as the list header
    AND inside the empty state (a pending request with no orders yet is the
    common case).
  • lib/features/provider/provider_product_list_screen.dart — a Visible/Hidden
    switch on every row, a "Hidden" marker, and a Delete whose dialog states
    the hide-instead rule; both call the new RPCs and report what happened.

Harness / tests:
  • tools/harness/static_checks.py — new check "Parts 9-11: every notification
    also pushes, the delivery fee is the ride fare, and a sold listing is
    hidden rather than deleted" (69 checks now), including a source-level
    guard that order_items -> products is never restated as ON DELETE CASCADE.
  • test/delivery_fee_reuses_the_ride_fare_test.dart — new: reads the deployed
    bodies, the column definition, FeeResolver, the checkout screen and
    order-create, and fails if any of them stops calling the shared reader.

NOT DONE, and why (9a):
  There is no FCM sender in this repository and there never was — no
  firebase_messaging in pubspec.yaml, no google-services.json, no sender in any
  migration or Edge Function, and nothing in lib/ ever writes fcm_tokens. A
  real OS-level push therefore needs the Firebase project's own credentials
  (an Android application-id registration and a service-account key), which
  cannot be invented in a migration. What IS delivered is the universal
  dispatch half: from the moment a token exists in fcm_tokens, every
  notification produces both the in-app row and a push event in the existing
  queue.
