// The checkout-approval gate, end to end, pinned at the seams that cannot be
// seen in a screenshot:
//
//   buyer submits  ->  order saved as AWAITING_APPROVAL  ->  waiting screen
//   admin decides  ->  approve (vehicle + driver + proof) or reject (reason)
//   approval       ->  realtime flips the buyer to the live map
//
// Most of the rules live in SQL (row lock, busy vehicle, role check, audit), so
// this test reads the migration and the screens together. A change that removes
// one half of a guarantee — the RPC check or the screen that relies on it —
// fails here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String path) {
  final f = File(path);
  if (!f.existsSync()) fail('missing file: $path');
  return f.readAsStringSync();
}

void main() {
  final enumSql = read(
      'supabase/migrations/20261108000001_checkout_approval_status.sql');
  final flowSql = read(
      'supabase/migrations/20261108000002_guest_checkout_and_checkout_approval.sql');
  final edge = read('supabase/functions/order-create/index.ts');
  final reviewEdge = read('supabase/functions/checkout-review/index.ts');
  final reviewScreen =
      read('lib/features/admin/admin_checkout_requests_screen.dart');

  group('the status exists in its own migration, in the right order', () {
    test('AWAITING_APPROVAL is added before any code uses it', () {
      expect(enumSql, contains("ADD VALUE IF NOT EXISTS 'AWAITING_APPROVAL'"));
      expect(enumSql, contains("BEFORE 'PENDING_PROVIDER'"));
      // Postgres cannot use a new enum value in the transaction that adds it.
      expect(flowSql, isNot(contains("ADD VALUE IF NOT EXISTS 'AWAITING_APPROVAL'")));
    });

    test('the flow migration says exactly where it deploys', () {
      expect(flowSql,
          contains('after 20261108000001 (the enum value), before the app build'));
    });
  });

  group('a guest can submit without a registration', () {
    test('the anonymous signup branch exists and returns early', () {
      expect(flowSql, contains('IF coalesce(new.is_anonymous, false) THEN'));
      expect(flowSql, contains("'APPROVED'::account_status"));
      expect(flowSql, contains('RETURN new;'));
    });

    test('the buyer contact is written onto the order, not a new profile', () {
      for (final col in const [
        'buyer_name',
        'buyer_phone',
        'buyer_note',
        'delivery_vehicle_id',
        'checkout_decided_at',
        'checkout_decided_by',
        'checkout_rejection_reason',
      ]) {
        expect(flowSql, contains('ADD COLUMN IF NOT EXISTS $col'),
            reason: '$col is part of the checkout record');
      }
    });

    test('an anonymous JWT cannot create a business identity', () {
      expect(flowSql, contains('prevent_anonymous_write'));
      expect(flowSql, contains("RAISE EXCEPTION 'GUEST_ACCOUNT_IS_READ_ONLY'"));
      for (final table in const [
        'provider_profiles',
        'products',
        'vehicles',
        'user_roles',
        'staff',
      ]) {
        expect(flowSql, contains("'$table'"),
            reason: '$table must be read-only for a guest JWT');
      }
    });
  });

  group('the order-create function wires the request', () {
    test('the buyer fields are validated before the order is created', () {
      expect(edge, contains('buyer_name'));
      expect(edge, contains('buyer_phone'));
      expect(edge, contains('buyer_note'));
      expect(edge, contains('A name is required for the delivery'));
      expect(edge, contains('A valid phone number is required for the delivery'));
    });

    test('request_approval is additive and old clients keep their path', () {
      expect(edge, contains('request_approval'));
      expect(edge, contains('body.request_approval === true'));
      expect(edge, contains('awaiting_approval: awaitingApproval'));
      expect(edge, contains('if (createdId && requestApproval)'));
    });

    test('attach and notify are separate so a push cannot undo an order', () {
      final attach = edge.indexOf("rpc(\n        \"attach_checkout_request\"");
      final submit = edge.indexOf("rpc(\n          \"submit_checkout_request\"");
      expect(attach, greaterThanOrEqualTo(0));
      expect(submit, greaterThan(attach));
      expect(edge, contains('a missing push must not undo it'));
    });
  });

  group('the admin decision is atomic and audited', () {
    test('the reviewer must be an admin and the decision is whitelisted', () {
      expect(flowSql,
          contains("RAISE EXCEPTION 'ONLY_AN_ADMINISTRATOR_MAY_DECIDE_A_CHECKOUT_REQUEST'"));
      expect(flowSql, contains("v_decision NOT IN ('APPROVE', 'REJECT')"));
    });

    test('the order row is locked so two admins cannot both decide', () {
      expect(flowSql,
          contains('SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE'));
      expect(flowSql, contains("RAISE EXCEPTION 'CHECKOUT_REQUEST_ALREADY_DECIDED'"));
    });

    test('rejecting requires a reason and tells the buyer', () {
      expect(flowSql, contains("RAISE EXCEPTION 'A_REJECTION_NEEDS_A_REASON'"));
      expect(flowSql, contains('checkout_rejection_reason = v_reason'));
      expect(flowSql, contains("'checkout-rejected:' || p_order_id::text"));
    });

    test('approving requires a vehicle, a driver and a payment proof', () {
      expect(flowSql, contains("RAISE EXCEPTION 'APPROVAL_REQUIRES_A_VEHICLE_AND_A_DRIVER'"));
      expect(flowSql, contains("RAISE EXCEPTION 'PAYMENT_PROOF_REQUIRED'"));
      expect(flowSql, contains('v_has_proof'));
      expect(flowSql, contains("verification_status = 'VERIFIED'"));
      // Service-role RPC: the reviewer id is verified and passed by the Edge
      // Function because a client-originated status change is refused.
      expect(flowSql, contains('verified_by = p_admin_id'));
      expect(flowSql, contains('p_admin_id IS NULL OR NOT EXISTS'));
    });

    test('the decision runs as a server write, after an ADMIN role check', () {
      expect(reviewEdge, contains('requireUser(req)'));
      expect(reviewEdge, contains('user_roles'));
      expect(reviewEdge, contains('row.role === "ADMIN"'));
      expect(reviewEdge, contains('p_admin_id: user.id'));
      expect(reviewEdge, contains('admin_review_checkout_request'));
      // The direct client RPC was refused by the order-status guard; the
      // screen must go through the endpoint instead.
      expect(reviewScreen, contains("'checkout-review'"));
      expect(reviewScreen, isNot(contains("rpc(\n        'admin_review_checkout_request'")));
      expect(flowSql,
          contains('TO service_role;'));
    });

    test('the vehicle must belong to the driver and neither may be busy', () {
      expect(flowSql, contains("RAISE EXCEPTION 'VEHICLE_DOES_NOT_BELONG_TO_THAT_DRIVER'"));
      expect(flowSql, contains("RAISE EXCEPTION 'VEHICLE_IS_NOT_AVAILABLE'"));
      expect(flowSql, contains("RAISE EXCEPTION 'VEHICLE_ALREADY_BUSY'"));
      expect(flowSql, contains("RAISE EXCEPTION 'DRIVER_ALREADY_BUSY'"));
    });

    test('approval assigns the vehicle and moves the order forward', () {
      expect(flowSql, contains('delivery_vehicle_id = p_vehicle_id'));
      expect(flowSql, contains('delivery_driver_provider_id = p_driver_provider_id'));
      expect(flowSql, contains("delivery_status = 'ASSIGNED'"));
      expect(flowSql, contains("SET status = 'APPROVED'"));
      expect(flowSql, contains("WHEN 'APPROVED' THEN o.status IN"));
    });

    test('every decision is in audit_logs and order history', () {
      expect(flowSql, contains("'CHECKOUT_REQUEST_APPROVED'"));
      expect(flowSql, contains("'CHECKOUT_REQUEST_REJECTED'"));
      expect(flowSql, contains("'CHECKOUT_REQUEST_CANCELLED_BY_BUYER'"));
      expect(flowSql, contains('INSERT INTO public.audit_logs'));
      expect(flowSql, contains('INSERT INTO public.order_status_history'));
    });

    test('buyer, driver and provider are notified once each', () {
      expect(flowSql, contains("'checkout-approved:' || p_order_id::text"));
      expect(flowSql, contains("'checkout-assigned:' || p_order_id::text"));
      // The driver is told where to collect the parcel as well as where to
      // take it, and the amount, not only that a job exists.
      expect(flowSql, contains("Pickup: "));
      expect(flowSql, contains("Drop-off: "));
      expect(flowSql, contains(". Amount: "));
      expect(flowSql, contains("':provider'"));
      expect(flowSql, contains('notify_user_safe'));
      // The idem keys are what makes a retry silent.
      expect(flowSql, contains("'checkout-request:' || p_order_id::text"));
      expect(flowSql, contains("'checkout-reminder:'"));
    });

    test('the buyer may cancel only while the request is pending', () {
      expect(flowSql, contains('FUNCTION public.cancel_checkout_request'));
      expect(flowSql, contains("RAISE EXCEPTION 'ONLY_THE_BUYER_MAY_CANCEL_THIS_REQUEST'"));
      expect(flowSql,
          contains("RAISE EXCEPTION 'CHECKOUT_REQUEST_CAN_ONLY_BE_CANCELLED_WHILE_PENDING'"));
    });

    test('reminders are deduplicated per order per hour', () {
      expect(flowSql, contains('notify_stale_checkout_requests'));
      expect(flowSql, contains("to_char(now(), 'YYYYMMDDHH')"));
      expect(flowSql, contains("interval '10 minutes'"));
    });
  });

  group('realtime moves the buyer to the map', () {
    test('orders is published and has a full row identity', () {
      expect(flowSql, contains('ALTER PUBLICATION supabase_realtime ADD TABLE public.orders'));
      expect(flowSql, contains('ALTER TABLE public.orders REPLICA IDENTITY FULL'));
    });

    test('the waiting screen listens first and polls only as a fallback', () {
      final screen = read('lib/features/user/checkout_waiting_screen.dart');
      expect(screen, contains(".stream(primaryKey: ['id'])"));
      expect(screen, contains('ResilientSubscription'));
      expect(screen, contains('Duration(seconds: 10)'));
      expect(screen, contains("status == 'APPROVED'"));
      expect(screen,
          contains("context.go('/user/orders/\${widget.orderId}/delivery')"));
    });

    test('the waiting screen survives a restart and can cancel', () {
      final screen = read('lib/features/user/checkout_waiting_screen.dart');
      expect(screen, contains('ActiveOrderStore.save(widget.orderId)'));
      expect(screen, contains("'checkout-cancel'"));
      expect(screen, contains('checkout_rejection_reason'));

      final dashboard = read('lib/features/user/user_dashboard.dart');
      expect(dashboard, contains('_resumeActiveOrder'));
      expect(dashboard, contains("status == 'AWAITING_APPROVAL'"));
      expect(dashboard, contains("context.go('/user/checkout/waiting/\$orderId')"));
      expect(dashboard, contains("status == 'APPROVED' || status == 'STARTED'"));
    });
  });

  group('the admin queue is reachable and complete', () {
    test('the route and the sidebar entry exist', () {
      final router = read('lib/routing/app_router.dart');
      expect(router, contains("path: '/admin/checkout-requests'"));
      final dashboard = read('lib/features/admin/admin_dashboard.dart');
      expect(dashboard, contains("'/admin/checkout-requests'"));
      expect(dashboard, contains('Checkout Requests'));
      expect(dashboard, contains("rpc('admin_checkout_request_count')"));
      expect(dashboard, contains("rpc('notify_stale_checkout_requests')"));
    });

    test('the queue has the four tabs, a search and the decision call', () {
      final screen = read('lib/features/admin/admin_checkout_requests_screen.dart');
      expect(screen,
          contains("_tabs = ['PENDING', 'APPROVED', 'REJECTED', 'ALL']"));
      expect(screen, contains("rpc('admin_checkout_requests'"));
      expect(screen, contains("rpc('admin_checkout_request_detail'"));
      expect(screen, contains("invoke(\n        'checkout-review'"));
      expect(screen, contains('APPROVE & ASSIGN'));
      expect(screen, contains('REJECT'));
      expect(screen, contains('adminDeliveryVehicles'));
    });

    test('the server refuses a non-admin before reading anything', () {
      expect(flowSql,
          contains("RAISE EXCEPTION 'ONLY_AN_ADMINISTRATOR_MAY_READ_CHECKOUT_REQUESTS'"));
      expect(flowSql,
          contains("RAISE EXCEPTION 'ONLY_AN_ADMINISTRATOR_MAY_READ_A_CHECKOUT_REQUEST'"));
      expect(flowSql, contains("RAISE EXCEPTION 'DELIVERY_VEHICLES_ARE_ADMIN_ONLY'"));
      expect(flowSql, contains("RAISE EXCEPTION 'ONLY_AN_ADMINISTRATOR_MAY_REMIND_ADMINS'"));
    });
  });

  group('checkout is delivery-only, in the UI and in the payload', () {
    test('the checkout writes DELIVERY and offers no pickup option', () {
      final checkout = read('lib/features/user/user_checkout_screen.dart');
      expect(checkout, contains("String _fulfillmentMode = 'DELIVERY';"));
      // No pickup CHOICE is offered. A basket made only of bookings keeps the
      // service flow's internal mode automatically; that is not a visible
      // option and is covered by the preserved booking path.
      expect(checkout, isNot(contains('I go to them')));
      expect(checkout, isNot(contains('Pickup at the')));
      expect(checkout, contains('Set the delivery point on the map'));
      expect(checkout, contains('buyerName: name'));
      expect(checkout, contains('buyerPhone: phone'));
      expect(checkout, contains('buyerNote: _notesCtrl.text.trim()'));
    });

    test('the payment step requires a proof and sends the approval request', () {
      final payment = read('lib/features/user/user_payment_screen.dart');
      expect(payment, contains("'request_approval': !draft.paymentDeferred"));
      expect(payment, contains('Attach the payment screenshot so the administrator'));
      expect(payment,
          contains("(raw['fulfillment_mode'] as String?) == 'SELF_PICKUP'"));
      // A buyer no longer uploads any identity document.
      expect(payment, isNot(contains('user-documents')));
    });

    test('old pickup orders keep a readable field, but no new writer', () {
      final edgeSrc = edge;
      expect(edgeSrc, contains('body.fulfillment_mode === "SELF_PICKUP"'),
          reason: 'old app versions may still send it and must not break');
      expect(edgeSrc, contains('"SELF_PICKUP" : "DELIVERY"'));
    });
  });

  group('the tracking screen moves the assigned vehicle', () {
    final tracking = read('lib/features/user/user_delivery_tracking_screen.dart');

    test('it draws the route and reports distance and minutes', () {
      expect(tracking, contains('routePoints:'));
      expect(tracking, contains('_distanceKm'));
      expect(tracking, contains('_etaMinutes'));
      expect(tracking, contains('km left'));
      expect(tracking, contains('About \$minutes min'));
      expect(tracking, contains('Arriving now'));
    });

    test('no GPS falls back to a marked simulation, stopped by a real fix', () {
      expect(tracking, contains('_maybeStartSimulation'));
      expect(tracking, contains('_simulated = true'));
      expect(tracking, contains('APPROXIMATE'));
      expect(tracking, contains('_simulated = false'));
    });

    test('it handles resume, cancellation and the delivered state', () {
      expect(tracking, contains('didChangeAppLifecycleState'));
      expect(tracking, contains("orderStatus == 'CANCELLED'"));
      expect(tracking, contains("case 'ARRIVED':"));
      expect(tracking, contains("case 'DELIVERED':"));
      expect(tracking, contains('ActiveOrderStore.clear()'));
    });
  });
}
