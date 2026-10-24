// =============================================================================
// fcm-dispatch — the FCM HTTP v1 sender (Firebase = transport only).
// =============================================================================
//
// WHY THIS EXISTS
// ---------------
// The database already writes EVERY user-facing notification into
// `notifications`, and an AFTER-INSERT trigger (`fn_enqueue_notification_push`,
// migration 20261015000001) assembles the recipient's active device tokens and
// writes one `n8n_events` row of type NOTIFICATION_PUSH carrying them. That
// trigger was written expecting an EXTERNAL n8n workflow to perform the send —
// which is not in this repository and never shipped. This function IS that
// sender: it consumes the `n8n_events` row the trigger already produced and
// delivers it over FCM HTTP v1. It is deliberately NOT a second notification
// pathway — it replaces the missing last hop of the one that exists.
//
// SECURITY (all five requirements)
// --------------------------------
//  * Service-account credential lives ONLY in a Supabase secret
//    (FIREBASE_SERVICE_ACCOUNT) — never in this repo, never in the client.
//  * The OAuth2 access token used to call FCM is minted from that service
//    account and CACHED in a module-level variable until shortly before it
//    expires, so a burst of notifications does not re-sign a JWT each time.
//  * Invoked only by a secured mechanism: a Supabase Database Webhook (or
//    pg_net) that authenticates with the service key (so the platform's
//    default `verify_jwt` passes) AND sends a shared `x-dispatch-secret`
//    header. A request without the correct secret is refused 403 — this is not
//    an open public endpoint.
//  * IDEMPOTENT: a notification is delivered at most once. Delivery is gated by
//    an atomic `UPDATE n8n_events ... WHERE status='PENDING'` claim; a retried
//    webhook for the same row finds it already claimed and is skipped.
//  * INVALID-TOKEN REAPING: an FCM response of UNREGISTERED / INVALID_ARGUMENT /
//    SENDER_ID_MISMATCH marks that `fcm_tokens.is_active = false` so the token
//    is never addressed again.
//
// SECRETS REQUIRED (set with `supabase secrets set`, see the checklist)
//   FIREBASE_SERVICE_ACCOUNT      JSON of a Firebase service account with the
//                                 Cloud Messaging API enabled.
//   FIREBASE_PROJECT_ID           the Firebase project id (the sender id
//                                 suffix in FCM v1 URLs).
//   NOTIFICATION_DISPATCH_SECRET  a long random shared secret the webhook sends
//                                 in the x-dispatch-secret header.
// (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by the platform.)
//
// TRIGGER (configured once, in the checklist): a Database Webhook on
// `n8n_events` INSERT -> invoke this function, forwarding the new row.

import { createClient } from "npm:@supabase/supabase-js@2";
import { importPKCS8, SignJWT } from "npm:jose@^5.9.6";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const FIREBASE_SERVICE_ACCOUNT = Deno.env.get("FIREBASE_SERVICE_ACCOUNT")!;
const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID")!;
const DISPATCH_SECRET = Deno.env.get("NOTIFICATION_DISPATCH_SECRET")!;

// The channel the client creates (see notification_service.dart). Naming it
// here means a pushed notification is posted to the same high-importance
// channel the app controls, rather than an unnamed default.
const ANDROID_CHANNEL = "aliob_updates";

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

// ---------------------------------------------------------------------------
// OAuth2 access token for FCM, minted from the service account and CACHED.
// ---------------------------------------------------------------------------
interface ServiceAccount {
  client_email: string;
  private_key: string;
}

let cachedToken: { value: string; expiresAt: number } | null = null;

async function getFcmAccessToken(): Promise<string> {
  // Reuse the cached token unless it expires within the next minute.
  if (cachedToken && Date.now() < cachedToken.expiresAt - 60_000) {
    return cachedToken.value;
  }

  const sa: ServiceAccount = JSON.parse(FIREBASE_SERVICE_ACCOUNT);
  const key = await importPKCS8(sa.private_key, "RS256");
  const now = Math.floor(Date.now() / 1000);

  // A signed JWT (RS256) granting the firebase.messaging scope, exchanged for
  // a short-lived OAuth2 access token at Google's token endpoint.
  const assertion = await new SignJWT({ scope: "https://www.googleapis.com/auth/firebase.messaging" })
    .setProtectedHeader({ alg: "RS256", typ: "JWT" })
    .setIssuer(sa.client_email)
    .setSubject(sa.client_email)
    .setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(key);

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!res.ok) {
    throw new Error(`OAuth token exchange failed: ${res.status} ${await res.text()}`);
  }
  const data = await res.json();
  cachedToken = {
    value: data.access_token as string,
    expiresAt: Date.now() + (data.expires_in as number) * 1000,
  };
  return cachedToken.value;
}

// ---------------------------------------------------------------------------
// One FCM HTTP v1 send. Returns the FCM error code on failure, or null on
// success. UNREGISTERED / INVALID_ARGUMENT / SENDER_ID_MISMATCH mean the token
// is dead and its fcm_tokens row must be reaped.
// ---------------------------------------------------------------------------
async function sendToOne(
  accessToken: string,
  token: string,
  payload: Record<string, unknown>,
): Promise<string | null> {
  // FCM v1 `data` values must all be strings; coerce defensively so a jsonb
  // number/bool never fails the whole send.
  const rawData = (payload.data ?? {}) as Record<string, unknown>;
  const data: Record<string, string> = {};
  for (const [k, v] of Object.entries(rawData)) {
    data[k] = typeof v === "string" ? v : JSON.stringify(v);
  }

  const body: Record<string, unknown> = {
    message: {
      token,
      notification: {
        title: String(payload.title ?? "Aliob"),
        body: String(payload.body ?? ""),
      },
      android: {
        priority: "high",
        notification: { channel_id: ANDROID_CHANNEL },
      },
    },
  };
  if (Object.keys(data).length > 0) {
    (body.message as Record<string, unknown>).data = data;
  }

  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${accessToken}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
    },
  );

  if (res.ok) return null;

  // Extract the machine-readable error code FCM reports for a dead token.
  try {
    const err = await res.json();
    const detail = err?.error?.details?.[0];
    return (detail?.errorCode ?? err?.error?.status ?? `HTTP_${res.status}`) as string;
  } catch {
    return `HTTP_${res.status}`;
  }
}

const DEAD_TOKEN_CODES = new Set([
  "UNREGISTERED",
  "INVALID_ARGUMENT",
  "SENDER_ID_MISMATCH",
  "THIRD_PARTY_AUTH_ERROR",
]);

// ---------------------------------------------------------------------------
// Handler
// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "method not allowed" }, 405);
  }

  // The shared-secret guard. The Database Webhook already authenticated with
  // the service key (satisfying verify_jwt); this second factor is what makes
  // the endpoint non-public even if the URL leaks.
  const provided = req.headers.get("x-dispatch-secret");
  if (!DISPATCH_SECRET || provided !== DISPATCH_SECRET) {
    return json({ error: "forbidden" }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid json" }, 400);
  }

  // Accept either the full Database-Webhook envelope (record = the n8n_events
  // row) or a bare { event_id } for reprocessing / the dev test harness.
  const record = (body.record ?? body) as Record<string, unknown>;
  const eventId = (record.id ?? body.event_id) as string | undefined;
  if (!eventId) {
    return json({ error: "no event id" }, 400);
  }

  // ---- Idempotency gate ----------------------------------------------------
  // Atomically claim the row PENDING -> SENT. Only one invocation can win this
  // UPDATE; a retried webhook for the same row finds it already SENT and is
  // skipped, so a notification is never sent twice. This is deliberately done
  // BEFORE the network sends: a crash mid-send can lose a push (the in-app
  // inbox already holds it) but can never duplicate one — the stated priority.
  const { data: claimed } = await admin
    .from("n8n_events")
    .update({ status: "SENT", processed_at: new Date().toISOString() })
    .eq("id", eventId)
    .eq("status", "PENDING")
    .select("id");
  if (!claimed || claimed.length === 0) {
    return json({ ok: true, skipped: "already processed" });
  }

  // ---- Load the payload (tokens + message) --------------------------------
  const payload = (record.payload ?? {}) as Record<string, unknown>;
  let tokens = Array.isArray(payload.tokens)
    ? (payload.tokens as unknown[]).map((t) => String(t)).filter((t) => t.length > 0)
    : [];

  // The ONE batched event in this system (admin "Notify all users of release",
  // APP_UPDATE_PUSH) carries a token_count and a batch_size but deliberately
  // NOT the token list itself — so a sender that only reads payload.tokens
  // claims the row, delivers to nobody, and reports "no tokens", which is a
  // broadcast that silently never reaches a single device. Assemble the list
  // here instead, from the same table the per-notification trigger reads.
  // notification_preferences.push_enabled is honoured per recipient, for the
  // same reason the trigger honours it: a stored preference that is not read
  // is worse than no preference. Ordering and the cap mirror the trigger and
  // the caller's batch_size (the in-app half of this broadcast is capped the
  // same way), so push and inbox cover the same window.
  if (tokens.length === 0 && payload.batched === true) {
    const cap = Math.max(1, Math.min(Number(payload.batch_size) || 500, 5000));
    const { data: rows, error } = await admin
      .from("fcm_tokens")
      .select("token, user_id")
      // Same predicates the per-notification trigger uses, so a device that
      // would be addressed by a normal push is addressed by the broadcast too
      // (coalesce(is_active, true) / coalesce(token, '') <> '').
      .or("is_active.eq.true,is_active.is.null")
      .neq("token", "")
      // Deterministic order, so a retried broadcast caps the SAME devices
      // rather than a different subset.
      .order("updated_at", { ascending: false, nullsFirst: false })
      .order("token", { ascending: true })
      .limit(cap);
    if (error) {
      await admin
        .from("n8n_events")
        .update({ status: "FAILED", last_error: error.message })
        .eq("id", eventId);
      return json({ error: "could not load broadcast tokens" }, 500);
    }
    const allowed = new Set<string>();
    const { data: prefs } = await admin
      .from("notification_preferences")
      .select("user_id, push_enabled")
      .eq("push_enabled", false);
    const optedOut = new Set((prefs ?? []).map((p) => String(p.user_id)));
    for (const row of rows ?? []) {
      if (!optedOut.has(String(row.user_id))) allowed.add(String(row.token));
    }
    tokens = [...allowed];
  }

  // An event with no device tokens (e.g. PROVIDER_APPROVED, which carries only
  // ids) has nothing to push to. It is still marked processed above.
  if (tokens.length === 0) {
    return json({ ok: true, skipped: "no tokens" });
  }

  let accessToken: string;
  try {
    accessToken = await getFcmAccessToken();
  } catch (e) {
    await admin
      .from("n8n_events")
      .update({ status: "FAILED", last_error: String(e) })
      .eq("id", eventId);
    return json({ error: "token exchange failed" }, 500);
  }

  // ---- Fan out, reaping dead tokens ---------------------------------------
  let sent = 0;
  const dead: string[] = [];
  for (const token of tokens) {
    const code = await sendToOne(accessToken, token, payload);
    if (code === null) {
      sent++;
    } else if (DEAD_TOKEN_CODES.has(code)) {
      dead.push(token);
    }
    // Transient errors (UNAVAILABLE, INTERNAL, QUOTA_*) are left alone: the
    // token stays active and the notification remains in the in-app inbox.
  }

  if (dead.length > 0) {
    // Reap every token FCM says no longer exists, so it is never addressed
    // again. Matched on token alone (a device token is globally unique).
    await admin.from("fcm_tokens").update({ is_active: false }).in("token", dead);
  }

  return json({ ok: true, sent, reaped: dead.length, total: tokens.length });
});
