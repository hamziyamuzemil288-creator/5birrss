// POST /checkout-cancel
// Body: { order_id }
//
// The buyer cancels their own still-pending checkout request from the waiting
// screen. A guest is an anonymous Supabase user, which requireUser() accepts;
// ownership is enforced by cancel_checkout_request itself.
//
// WHY AN ENDPOINT: cancelling changes orders.status. The order-status guard
// accepts a status change only from a server write, so the direct client RPC
// was refused even for the order's own buyer. The function is now
// service-role only and this endpoint supplies the verified buyer id.
import {
  corsHeaders,
  getAdminClient,
  json,
  requireUser,
  sanitizeError,
} from "../_shared/client.ts";
import { handleCatch } from "../_shared/errors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { user } = await requireUser(req);
    const body = await req.json().catch(() => ({}));
    const orderId = (body.order_id ?? "").toString().trim();
    if (!orderId) return json({ error: "order_id required" }, 400);

    const admin = getAdminClient();
    const { data, error } = await admin.rpc("cancel_checkout_request", {
      p_order_id: orderId,
      p_user_id: user.id,
    });

    if (error) {
      return json({ error: sanitizeError(error.message) }, 400);
    }
    return json(data ?? { ok: true, status: "CANCELLED" });
  } catch (e) {
    return handleCatch(e, "checkout-cancel:cancel");
  }
});
