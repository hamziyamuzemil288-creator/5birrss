// =============================================================================
// signin-welcome — one real "Welcome back" after an explicit sign-in
// =============================================================================
//
// Why this is an Edge Function instead of a direct client RPC:
//
// The SQL function that owns the dedupe, the five-minute gap, the token check
// and the template is `record_signin_welcome_for_user`. It must run as the
// SERVICE ROLE, not as the caller. A caller-role notification goes into
// `notification_outbox` and waits for the once-a-minute pg_cron drain, so the
// inbox row and the push can be up to a minute late. The sign-in welcome is
// read immediately by a person who just signed in, so it takes the direct
// server path: notification row -> enqueue trigger -> n8n -> fcm-dispatch.
//
// This function is the only caller that may supply a user id. It never trusts
// one from the request: it verifies the caller's own JWT with the admin API,
// then passes THAT user id and the JWT's session id to the service-role RPC.
// There is no parameter that can address somebody else.
//
// JWT verification stays ON. The gateway has already rejected a missing or
// invalid session before this body runs; `getUser` re-checks the same token
// against the auth server so a stale/revoked token cannot slip through.
//
// Client: lib/core/services/welcome_back_service.dart, called ONLY from the
// `AuthChangeEvent.signedIn` branch in AuthNotifier. It is deliberately not
// called for initialSession, tokenRefreshed, or app resumes.
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

/// Read the already-verified token's session id. getUser() above is what makes
/// the payload trustworthy; this does not verify a signature itself.
function sessionIdFromToken(token: string): string {
  try {
    const part = token.split(".")[1];
    if (!part) return "";
    const normalized = part.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized.padEnd(
      Math.ceil(normalized.length / 4) * 4,
      "=",
    );
    const bytes = Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
    const payload = JSON.parse(new TextDecoder().decode(bytes));
    return typeof payload?.session_id === "string" ? payload.session_id : "";
  } catch (e) {
    console.error("signin-welcome: could not read the session id", e);
    return "";
  }
}

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

  let allowInboxOnly = false;
  try {
    const body = await req.json();
    allowInboxOnly = body?.allow_inbox_only === true;
  } catch (_) {
    // An empty body is the ordinary case. No input means "require a token",
    // which is the safer default.
  }

  const { data, error } = await admin.rpc("record_signin_welcome_for_user", {
    p_user_id: user.id,
    p_session_id: sessionIdFromToken(token),
    p_allow_inbox_only: allowInboxOnly,
  });

  if (error) {
    console.error("signin-welcome: rpc failed", error);
    return json(
      { ok: false, status: "failed", error: "could not record the welcome" },
      500,
    );
  }

  return json(data);
});
