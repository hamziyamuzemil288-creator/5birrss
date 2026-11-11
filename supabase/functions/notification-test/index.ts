// =============================================================================
// notification-test — one authenticated tap, one real notification
// =============================================================================
//
// The Notification Settings screen needs to prove the whole chain, not just
// that a browser can reach the project:
//
//   auth user -> notifications row -> enqueue trigger -> n8n_events
//             -> fcm-dispatch -> FCM -> phone tray
//
// A client cannot insert into `notifications` (prevent_notification_injection
// refuses clients by design), and queuing through notify_user() would make the
// button wait for the minute cron. This function is the narrow server door:
// it verifies the caller's own JWT, writes ONE notification addressed to that
// caller, and returns whether there was an active device token to address.
//
// It never accepts a target user id. A caller can only test themselves, so
// this cannot become a way to notify somebody else.
// =============================================================================

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const auth = req.headers.get("authorization") ?? "";
  const token = auth.toLowerCase().startsWith("bearer ")
    ? auth.slice(7).trim()
    : "";
  if (!token) return json({ error: "missing bearer token" }, 401);

  const { data: userData, error: userError } = await admin.auth.getUser(token);
  const user = userData?.user;
  if (userError || !user) {
    return json({ error: "invalid session" }, 401);
  }

  const { count: activeTokens, error: tokenError } = await admin
    .from("fcm_tokens")
    .select("id", { count: "exact", head: true })
    .eq("user_id", user.id)
    .or("is_active.eq.true,is_active.is.null")
    .neq("token", "");

  if (tokenError) {
    console.error("notification-test: token lookup failed", tokenError);
  }

  const { data: row, error } = await admin
    .from("notifications")
    .insert({
      user_id: user.id,
      type: "ADMIN_MESSAGE",
      title: "Aliob test notification",
      body:
        "If this is in your notification tray, Aliob push is working. " +
        "The same notice is in your in-app inbox.",
      data: { event: "test_notification" },
    })
    .select("id")
    .single();

  if (error) {
    console.error("notification-test: insert failed", error);
    return json({ error: "could not create the test notification" }, 500);
  }

  return json({
    ok: true,
    notification_id: row.id,
    active_tokens: activeTokens ?? 0,
    // An inbox-only test is still useful, but the screen must say so rather
    // than claim the phone tray is working.
    tray_expected: (activeTokens ?? 0) > 0,
  });
});
