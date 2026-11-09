// Shared helper for Supabase Edge Functions (Deno runtime).
// Two clients:
//  - userClient: acts AS the calling user (respects RLS) — used to verify identity/role.
//  - adminClient: service_role — used ONLY to call SECURITY DEFINER functions
//    after we've validated the caller ourselves. Never forward service_role to the client.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

export function getAdminClient() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } }
  );
}

export function getUserClient(authHeader: string) {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } }
  );
}

export async function requireUser(req: Request) {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) throw new Response("Missing Authorization header", { status: 401 });
  const userClient = getUserClient(authHeader);
  const { data, error } = await userClient.auth.getUser();
  if (error || !data.user) throw new Response("Invalid session", { status: 401 });
  return { user: data.user, userClient };
}

/**
 * Verify the authenticated user holds a specific role using the admin client.
 * This reads from user_roles (server-populated) — never trusts client claims.
 */
export async function requireRole(req: Request, role: string) {
  const { user, userClient } = await requireUser(req);
  const admin = getAdminClient();
  const { data: roles } = await admin.from("user_roles").select("role").eq("user_id", user.id);
  const has = (roles ?? []).some((r: { role: string }) => r.role === role);
  if (!has) throw new Response(JSON.stringify({ error: `ROLE_REQUIRED:${role}` }), { status: 403 });
  return { user, userClient };
}

export function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

/**
 * Sanitize error messages to prevent leaking internal implementation details.
 * Only returns safe, user-facing error codes, not raw SQL/DB errors.
 */
export function sanitizeError(msg: string): string {
  // Known safe error codes to pass through
  const safeCodes = [
    "RIDE_ALREADY_TAKEN", "RIDE_REQUEST_EXPIRED",
    "VEHICLE_NOT_ELIGIBLE", "PROVIDER_NOT_ELIGIBLE",
    "WALLET_NOT_FOUND", "INSUFFICIENT_WALLET_BALANCE", "ORDER_NOT_FOUND",
    "RIDE_NOT_FOUND", "RECHARGE_REQUEST_NOT_FOUND", "RECHARGE_REQUEST_IS_NOT_PENDING",
    "PROVIDER_NOT_FOUND", "PROVIDER_MISMATCH", "FORBIDDEN", "UNAUTHORIZED",
    "INVALID_TRANSITION", "PAYMENT_PROOF_REQUIRED", "LOCATION_REQUIRED_TO_GO_ONLINE",
    "NOT_YOUR_DRIVER_STATUS", "CANNOT_CREATE_RIDE_FOR_ANOTHER_USER",
    "AMOUNT_MUST_BE_POSITIVE", "AMOUNT_CANNOT_BE_ZERO",
    "WALLET_NOT_FOUND_FOR_PROVIDER", "INSUFFICIENT_BALANCE_FOR_DEBIT",
    "ONLY_ADMINISTRATORS", "ADMINISTRATORS_CANNOT", "ROLE_REQUIRED",
    "ONLY_CLAIMING_PROVIDER", "ONLY_RIDER_OR_ADMIN", "RIDE_ALREADY_TERMINAL",
    "RECHARGE_STATUS_CAN_ONLY", "SUBSCRIPTION_STATUS_CANNOT_BE_SELF_MODIFIED",
    // Provider/profile approval flow (see 0029/0030/0033/0034 server-path fixes)
    "PROFILE_STATUS_CANNOT_BE_SELF_MODIFIED", "STATUS_CANNOT_BE_SELF_MODIFIED",
    "CANNOT_APPROVE_OWN_ACCOUNT", "ONLY_ADMINISTRATORS",
    // Category-coded order numbers are allocated server-side only (0037)
    "ORDER_NUMBERS_ARE_SERVER_ALLOCATED",
    // One-time activation / zero-balance wallet gates (see 0038) — buyers get
    // the specific reason so the app can route them to the waiting screen.
    "PROVIDER_NOT_ACTIVATED", "PROVIDER_WALLET_EMPTY", "REGISTRATION_FEE_REQUIRED",
    // Admin checkout approval (20261108000002): these are the refusal codes the
    // review sheet explains in place (busy vehicle/driver, already decided, a
    // missing proof, a rejection without a reason). Everything else stays
    // generic on purpose.
    "ONLY_AN_ADMINISTRATOR_MAY_DECIDE_A_CHECKOUT_REQUEST",
    "DECISION_MUST_BE_APPROVE_OR_REJECT",
    "CHECKOUT_REQUEST_ALREADY_DECIDED",
    "A_REJECTION_NEEDS_A_REASON",
    "APPROVAL_REQUIRES_A_VEHICLE_AND_A_DRIVER",
    "DRIVER_MUST_BE_AN_APPROVED_VEHICLE_PROVIDER",
    "VEHICLE_NOT_FOUND", "VEHICLE_DOES_NOT_BELONG_TO_THAT_DRIVER",
    "VEHICLE_IS_NOT_AVAILABLE", "VEHICLE_DOES_NOT_MATCH_THE_CHOSEN_TYPE",
    "VEHICLE_ALREADY_BUSY", "DRIVER_ALREADY_BUSY",
    // Guest checkout cancellation (20261108000002)
    "ONLY_THE_BUYER_MAY_CANCEL_THIS_REQUEST",
    "CHECKOUT_REQUEST_CAN_ONLY_BE_CANCELLED_WHILE_PENDING",
  ];
  for (const code of safeCodes) {
    if (msg.includes(code)) return msg;
  }
  // Unknown error: return generic message
  return "An internal error occurred. Please try again.";
}
