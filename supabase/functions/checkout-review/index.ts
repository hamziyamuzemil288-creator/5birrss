// POST /checkout-review
// Body: { order_id, decision: "APPROVE" | "REJECT", reason?,
//         vehicle_category_id?, vehicle_id?, driver_provider_id? }
//
// WHY THIS IS AN EDGE FUNCTION AND NOT A DIRECT RPC
// -------------------------------------------------
// Approving a checkout changes orders.status, and the trigger
// prevent_order_self_privilege_escalation accepts a status change ONLY from a
// server write. An ADMIN JWT is still a client write, so the previous direct
// `client.rpc('admin_review_checkout_request')` was refused by the guard it
// was supposed to satisfy. The function is now EXECUTE-granted to service_role
// alone; this endpoint authenticates the caller's JWT, verifies the ADMIN role
// from user_roles with the service client (never from a claim), and only then
// calls the RPC with that verified id.
//
// The RPC itself re-checks that the id holds ADMIN, row-locks the order, and
// does the assignment, history, audit and notifications in one transaction.
import {
  corsHeaders,
  getAdminClient,
  json,
  requireUser,
  sanitizeError,
} from "../_shared/client.ts";
import { handleCatch } from "../_shared/errors.ts";

const DECISIONS = new Set(["APPROVE", "REJECT"]);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { user } = await requireUser(req);
    const body = await req.json().catch(() => ({}));

    const orderId = (body.order_id ?? "").toString().trim();
    const decision = (body.decision ?? "").toString().trim().toUpperCase();
    const reason = body.reason == null ? null : body.reason.toString().trim();

    if (!orderId) return json({ error: "order_id required" }, 400);
    if (!DECISIONS.has(decision)) {
      return json({ error: "DECISION_MUST_BE_APPROVE_OR_REJECT" }, 400);
    }

    const admin = getAdminClient();

    // Identity comes from the verified JWT; the ROLE comes from the table. An
    // anonymous guest has no row here, so this is also the guest refusal.
    const { data: roles, error: roleError } = await admin
      .from("user_roles")
      .select("role")
      .eq("user_id", user.id);
    if (roleError) {
      console.error("checkout-review: role lookup failed", roleError);
      return json({ error: "FORBIDDEN" }, 403);
    }
    const isAdmin = (roles ?? []).some(
      (row: { role?: string }) => row.role === "ADMIN",
    );
    if (!isAdmin) return json({ error: "FORBIDDEN" }, 403);

    const { data, error } = await admin.rpc(
      "admin_review_checkout_request",
      {
        p_order_id: orderId,
        p_decision: decision,
        p_reason: reason && reason.length > 0 ? reason.slice(0, 500) : null,
        p_vehicle_category_id: body.vehicle_category_id ?? null,
        p_vehicle_id: body.vehicle_id ?? null,
        p_driver_provider_id: body.driver_provider_id ?? null,
        p_admin_id: user.id,
      },
    );

    if (error) {
      // Codes the review screen can explain; unknown database text is never
      // forwarded raw (sanitizeError returns a generic sentence).
      return json({ error: sanitizeError(error.message) }, 400);
    }

    return json(data ?? { ok: true });
  } catch (e) {
    return handleCatch(e, "checkout-review:review");
  }
});
