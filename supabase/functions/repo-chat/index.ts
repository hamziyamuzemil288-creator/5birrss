// Supabase Edge Function: in-app help agent for end users.
// Free mode only — no LLM, no API keys. Fast paths handle greetings and the
// app's core flows; anything else is answered from the indexed repo, and
// anything the agent can't answer gets a friendly handoff to human support.
// Env: LLM_PROVIDER (default "none").
import { createClient } from "npm:@supabase/supabase-js@2";

declare const Supabase: any; // provided by the Supabase Edge runtime

const DAILY_LIMIT = 50; // messages per user per day
// Only the free retrieval mode exists today. Reserve the knob for the future.
const LLM_PROVIDER = (Deno.env.get("LLM_PROVIDER") ?? "none").toLowerCase();
if (LLM_PROVIDER !== "none") {
  console.warn(`LLM_PROVIDER "${LLM_PROVIDER}" is not supported in this build; using "none".`);
}

// ── Contact info policy (Task 14) ────────────────────────────────────────
// The bot NEVER emits personal/direct contact details — no phone numbers,
// no WhatsApp links, no email addresses — under any circumstance. Every
// unresolved situation escalates to the in-app Appeal Page instead (the
// form already collects the user's own contact details and evidence; CEO
// and assigned staff see and answer the case via the Task 12 roles/staff
// system). Deep links are in-app routes only.

// ── Escalation to the Appeal Page (Task 14) ─────────────────────────────
// Complaints / reports / disputes / anything the bot cannot resolve are
// handed to the appeal flow with context so the case lands correctly.

interface ProviderContext {
  isProvider: boolean;
  displayName: string;
}

async function loadProviderContext(userId: string): Promise<ProviderContext> {
  try {
    const { data: roles } = await admin
      .from("user_roles")
      .select("role")
      .eq("user_id", userId);
    const isProvider = (roles ?? []).some((r: { role: string }) =>
      r.role === "VEHICLE_PROVIDER" || r.role === "SERVICE_PROVIDER"
    );
    if (!isProvider) return { isProvider: false, displayName: "" };
    const { data: profile } = await admin
      .from("profiles")
      .select("full_name")
      .eq("id", userId)
      .maybeSingle();
    return { isProvider: true, displayName: (profile?.full_name as string) ?? "" };
  } catch (e) {
    console.error("loadProviderContext failed:", e);
    return { isProvider: false, displayName: "" };
  }
}

const ISSUE_RE =
  /\b(not\s*(responding|answering|picking)|no\s*response|isn'?t\s*(responding|answering)|is\s*not\s*(responding|answering)|unresponsive|ignored?|ghosted|silent|scammed?|ripped|disappeared|won'?t\s*(reply|answer|respond|deliver)|refuses?\s*to\s*(reply|answer|respond|deliver|refund)|stuck|no\s*(update|progress)|where\s*is\s*(my|the)\s*(order|money|refund|delivery)|order\s*(problem|issue)|payment\s*(problem|issue|failed)|money\s*(lost|stuck)|delivery\s*(problem|issue)|complain(t|)|report\s*(a|an|the)?\s*(seller|provider|driver|user|problem|issue))\b/i;

function looksLikeIssue(text: string): boolean {
  return ISSUE_RE.test(text);
}

// ── Appeal / spam-report intent (routes to the user appeal form) ──────────
const APPEAL_RE =
  /\b(appeals?|banned?|unban|suspend(ed|sion)?|flagged|spam(?:my|mer|ming)?|report\s+(?:a\s+|an\s+|the\s+)?(?:spam|abuse|scam(?:mer)?)|wrongly\s+(?:banned|flagged|suspended)|my\s+(?:account|shop|store)\s+(?:was|is|got|has\s+been)\s+(?:banned|suspended|flagged|closed|blocked)|account\s+(?:banned|suspended|blocked))\b/i;

function isAppealIntent(text: string): boolean {
  return APPEAL_RE.test(text);
}

function appealReply(): string {
  return (
    "I'm sorry you're dealing with that — let's get it in front of our team properly.\n\n" +
    "The appeal form lets you attach a photo as evidence and describe exactly what " +
    "happened. Our team reviews every appeal and follows up with you inside the app.\n\n" +
    "Tap \"Submit an appeal\" below to get started — or tell me a bit more here if " +
    "you'd prefer."
  );
}

// ── Context-aware escalation (Task 14): different parties have different
// underlying issues. Detect WHO is speaking and WHAT KIND of problem it is,
// so the appeal form opens pre-tagged and the case lands with the right
// review context instead of a generic report.
const DISPUTE_RE =
  /\b(scammed?|ripped|fraud|stole|stolen|money\s*(lost|stuck|gone)|where\s*(is|are)\s*(my|the)\s*(money|refund)|not\s*refunded?|won'?t\s*refund|false\s*(advert|claim|listing)|fake\s*(product|seller|provider|driver)|\bis\s*(a\s*)?fake\b|counterfeit|never\s*(delivered|sent|arrived)|order\s*never)\b/i;
const COMPLAINT_RE =
  /\b(complain(t|)|report\s*(a|an|the)?\s*(seller|provider|driver|user|person|rider|him|her|them)|bad\s*(service|behavior|attitude)|rude|harass|insult|threat|unprofessional|late\s*delivery|damaged|broken\s*(item|product)|wrong\s*(item|order)|not\s*(responding|answering|picking)|no\s*response|unresponsive|ignored?|ghosted|silent)\b/i;
// TODO(post-build): the double-nested group above is intentionally kept
// identical to the tested harness copy; do not "simplify" without re-running
// tools/test/repo_chat_harness.mjs.
const ACCOUNT_RE =
  /\b(banned?|unban|suspend(ed|sion)?|flagged|blocked|locked\s*out|closed\s*(my|the)\s*account|rejected|approval|approved\?)\b/i;
const RIDER_RE =
  /\b(ride|driver|trip|taxi|pickup|fare)\b/i;

function isDisputeIntent(text: string): boolean {
  return DISPUTE_RE.test(text);
}

function isComplaintIntent(text: string): boolean {
  return COMPLAINT_RE.test(text);
}

function isAccountIntent(text: string): boolean {
  return ACCOUNT_RE.test(text);
}

function isRiderIntent(text: string): boolean {
  return RIDER_RE.test(text);
}

interface AppealContext {
  about: "rider" | "provider" | "dispute" | "account" | "general";
}

/** Classify an escalation: WHO/WHAT the appeal is about, so the appeal form
 *  opens pre-tagged. Providers keep their provider context; riders get the
 *  rider tag; money/dispute language outranks general complaints. */
function classifyAppeal(text: string, isProvider: boolean): AppealContext {
  if (isDisputeIntent(text) || isComplaintIntent(text)) {
    if (isRiderIntent(text)) return { about: "rider" };
    if (isProvider) return { about: "provider" };
    return { about: "dispute" };
  }
  if (isAccountIntent(text)) return { about: "account" };
  if (isProvider) return { about: "provider" };
  return { about: "general" };
}

/** The escalation reply: one authoritative hand-off to the Appeal Page. */
function escalationReply(ctx: AppealContext): string {
  const aboutLine = {
    rider: "It will be tagged as a ride/driver issue.",
    provider: "It will be tagged with your provider context.",
    dispute: "It will be tagged as a buyer–seller dispute.",
    account: "It will be tagged as an account/status issue.",
    general: "",
  }[ctx.about];
  return (
    "I can't resolve this myself, so let's put it in front of our team the right way.\n\n" +
    "Tap \"Submit an appeal\" below — the form lets you attach a photo as evidence, " +
    "describe exactly what happened, and include how the team should reach you. " +
    (aboutLine ? aboutLine + " " : "") +
    "Our team reviews every appeal and follows up with you inside the app."
  );
}

// ── Input normalization: tolerant matching for real-world typing ─────────
// Lowercases, normalizes quotes, expands common chat shorthand, fixes common
// typos/misspells, and collapses whitespace. Used for DETECTION only — stored
// content (ticket answers, etc.) always uses the raw message.
// The typo fixes here are also mirrored in tools/test/repo_chat_harness.mjs
// (run `node tools/test/repo_chat_harness.mjs` after changing them).
function norm(s: string): string {
  return s
    .toLowerCase()
    .replace(/[\u2018\u2019]/g, "'")
    .replace(/[\u201C\u201D]/g, '"')
    // Contractions join ("how's" → "hows", "i'm" → "im") so the greeting
    // and self-report patterns below match both written forms.
    .replace(/'/g, "")
    // Emoji, variation selectors and ZWJ are chatter, never content. Stripped
    // up front so "hi 👋" and "thanks 🙏" still whole-match their tiers.
    .replace(/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\uFE0F\u200D]/gu, " ")
    // Common ASCII emoticons — explicit forms only; a bare ":" would eat
    // times and email addresses.
    .replace(/(?:^|\s)(?:[:;=8]-?[()dDpP]|[xX]d|<3)(?=\s|$)/g, " ")
    // Typo tolerance — greetings & thanks first (transpositions, missing/doubled
    // letters), then the shorthand expansions below catch the rest.
    .replace(/\b(he(ll|lo)l|heello|helo)\b/g, "hello")
    .replace(/\b(hwo|howw)\b/g, "how")
    .replace(/\b(yuo|uyo)\b/g, "you")
    .replace(/\b(tank|tahnk|thnak|thansk|thnks|tks|thx|thnx|tnx|tq)\b/g, "thanks")
    .replace(/\bthank(?:\s+(?:you|yuo|u))?\b/g, "thanks")
    .replace(/\bthanks\s+(?:you|yuo|u)\b/g, "thanks")
    // (Task 14 fix) alternation precedence: the previous form
    // \b(?:many|so\s+much)\s+thanks\b could never match because the group
    // binds to \s+thanks inside the alternation — split the variants.
    .replace(/\bmany\s+thanks\b/g, "thanks")
    .replace(/\bso\s+much\s+thanks\b/g, "thanks")
    .replace(/\b(pleasse|plesae|plese)\b/g, "please")
    .replace(/\b(hep|hepl|heelp|halp)\b/g, "help")
    // App-word typos that otherwise break the topic match entirely.
    .replace(/\b(cancle|canel|cancell)\b/g, "cancel")
    .replace(/\b(regsiter|reigster|regster|regiter)\b/g, "register")
    .replace(/\b(uplod|uplaud|uplod)\b/g, "upload")
    .replace(/\b(notificaton|notifcation|notificationn)s?\b/g, "notifications")
    .replace(/\b(whats|wat|whut|waht)\b/g, "what")
    // Chat shorthand.
    .replace(/\bhw\b/g, "how")
    .replace(/\br\b/g, "are")
    .replace(/\bplz|pls\b/g, "please")
    .replace(/\bu\b/g, "you")
    .replace(/\bur\b/g, "your")
    .replace(/\bi\s+wnt\b/g, "i want")
    // ── Structural chatter tolerance (friendliness task) ──
    // Chat slang that only ever appears as a standalone token.
    .replace(/\bhlw\b/g, "hello")
    .replace(/\bhru\b/g, "how are you")
    // Gratitude qualifiers collapse to bare "thanks" so the thanks tier
    // stays a whole-message match ("thanks a lot", "thank you so much",
    // "many thanks", "great thanks", "got it thanks", "thanks sm", ...).
    .replace(/\bthanks\s+(?:so|very)\s+much\b/g, "thanks")
    .replace(/\bthanks\s+a\s+(?:lot|million|ton|bunch)\b/g, "thanks")
    .replace(/\bthanks[,.]?\s+(?:sm|alot|bro|man|mate|buddy|guys|dear|sir|madam|admin|friend)\b/g, "thanks")
    .replace(/\b(?:many|so\s+much)\s+thanks\b/g, "thanks")
    .replace(/\b(?:got\s*it|ok|okay|alright|great|awesome|perfect|fine|good|nice|works)\s+thanks\b/g, "thanks")
    // "thanks bye" / "tnx bye" are farewells, not gratitude.
    .replace(/\bthanks\s+bye\b/g, "bye")
    // "hi there / hi friend / hello team" collapse to the bare greeting —
    // safe because a real question never starts "hi there how ..." and stay
    // whole-message below.
    .replace(/\b(hi|hello|hey|selam|hallo)\s+(?:there|friend|bros?|guys|team|everyone|dear|all|folks|fam|aliob|admin)\b/g, "$1")
    // "how are you today / doing today" and "how is your day going" collapse
    // into forms the greeting / small-talk tiers already match.
    .replace(/\bhow\s+are\s+you\s+(?:doing\s+)?(?:today|this\s+(?:morning|afternoon|evening|night))\b/g, "how are you")
    .replace(/\b(?:hows?|how\s+is|how\s+was)\s+(?:your|ur)\s+day\s+going\b/g, "hows your day")
    // The natural reply to the assistant's own "how are you?" is a
    // return-question — mark it so the dedicated tier catches it.
    .replace(/\b(?:what|how)\s+about\s+you\b/g, "and you")
    .replace(/\bhow\s+about\s+yourself\b/g, "and you")
    .replace(/\byourself\b/g, "and you")
    .replace(/\s+/g, " ")
    .trim();
}

// ── Follow-up memory (in-memory, 30-min TTL, per isolate) ─────────────────
// Remembers the user's last few messages so short follow-ups like "and rides?"
// resolve against the recent conversation instead of dead-ending.
const msgHistory = new Map<string, string[]>();
const historyTimestamps = new Map<string, number>();
const HISTORY_TTL_MS = 30 * 60 * 1000;

function rememberMessage(userId: string, q: string): void {
  const ts = historyTimestamps.get(userId);
  if (ts && Date.now() - ts > HISTORY_TTL_MS) msgHistory.set(userId, []);
  const arr = msgHistory.get(userId) ?? [];
  arr.push(q);
  if (arr.length > 3) arr.shift();
  msgHistory.set(userId, arr);
  historyTimestamps.set(userId, Date.now());
}

function withRecentContext(userId: string, q: string): string {
  const arr = msgHistory.get(userId) ?? [];
  const prev = arr.slice(0, -1); // exclude the current message
  if (!prev.length) return q;
  return [...prev.slice(-2), q].join(" ");
}

// Details collected across the guided flow: the bot asks for the provider's
// name/ID, their city, the user's own phone number, then the order number and
// a short description before submitting everything as a support ticket.
interface TicketDraft {
  providerName?: string;
  providerCity?: string;
  reporterPhone?: string;
  orderNumber?: string;
  description?: string;
  step: number;
}

const TICKET_QUESTIONS = [
  "I'm sorry you're dealing with this — let me get it to our support team right away.\n\n" +
    "First, what is the other party's name, ID or phone number (whichever you have)?",
  "Thank you. Which city did this happen in?",
  "What is YOUR phone number? Our team will use it to contact you about this issue.",
  "Got it. Do you have the order number (it looks like Vh00012, Ht00003 or Fd00007)? If you don't know it, just write 'no'.",
  "Last thing — briefly describe what happened.",
];

const TICKET_STEPS = TICKET_QUESTIONS.length; // 5 questions → 5 answers

const VALID_ETHIOPIAN_PHONE = /^(?:\+?251|0)?9\d{8}$/;

function normalizePhone(raw: string): string | null {
  const digits = raw.replace(/[^\d+]/g, "");
  if (!VALID_ETHIOPIAN_PHONE.test(digits)) return null;
  if (digits.startsWith("+251")) return "0" + digits.slice(4);
  if (digits.startsWith("251")) return "0" + digits.slice(3);
  return digits.startsWith("0") ? digits : "0" + digits;
}

// Matches a bare order number, optionally preceded by "order (number/no./#):" —
// anything wordier is treated as a description or a "no".
const ORDER_NUMBER_RE = /^\s*(?:order\s*(?:number|no\.?|#)?\s*[:\-]?)?\s*([A-Za-z]{2}\d{3,8})\s*$/;

function parseOrderNumber(raw: string): string | null {
  const m = raw.match(ORDER_NUMBER_RE);
  return m ? m[1].toUpperCase() : null;
}

function ticketSessionKey(userId: string): string {
  return `ticket:${userId}`;
}

// In-memory ticket drafts. Each Edge Function isolate serves the same user's
// consecutive messages in practice (same region, sticky routing), and the
// flow is resilient: if the isolate is recycled mid-flow the user simply
// restarts it — no data is lost because nothing was submitted yet.
const ticketSessions = new Map<string, TicketDraft>();
const SESSION_TTL_MS = 30 * 60 * 1000;
const sessionTimestamps = new Map<string, number>();

function getSession(userId: string): TicketDraft | undefined {
  const ts = sessionTimestamps.get(userId);
  if (ts && Date.now() - ts > SESSION_TTL_MS) {
    ticketSessions.delete(userId);
    sessionTimestamps.delete(userId);
    return undefined;
  }
  return ticketSessions.get(userId);
}

function setSession(userId: string, draft: TicketDraft) {
  // Bound memory: drop the oldest third of sessions beyond 500.
  if (ticketSessions.size > 500) {
    const entries = [...sessionTimestamps.entries()].sort((a, b) => a[1] - b[1]);
    for (const [k] of entries.slice(0, Math.floor(entries.length / 3))) {
      ticketSessions.delete(k);
      sessionTimestamps.delete(k);
    }
  }
  ticketSessions.set(userId, draft);
  sessionTimestamps.set(userId, Date.now());
}

function clearSession(userId: string) {
  ticketSessions.delete(userId);
  sessionTimestamps.delete(userId);
}

interface TicketInput {
  userId: string;
  draft: Required<Pick<TicketDraft, "providerName" | "providerCity" | "reporterPhone" | "orderNumber" | "description">>;
}

async function submitTicket(
  { userId, draft }: TicketInput,
): Promise<boolean> {
  const { error } = await admin.from("support_tickets").insert({
    user_id: userId,
    subject: `Order/payment issue — other party not responding (provider: ${draft.providerName})`,
    status: "OPEN",
    source: "HELP_CHAT",
    reporter_phone: draft.reporterPhone,
    provider_name: draft.providerName,
    provider_reference: draft.providerName,
    provider_city: draft.providerCity,
    order_number: draft.orderNumber === "NO" ? null : draft.orderNumber,
    description: draft.description,
  });
  if (error) {
    console.error("submitTicket failed:", error.message);
    return false;
  }
  return true;
}

function ticketThankYou(draft: TicketDraft): string {
  const order = draft.orderNumber && draft.orderNumber !== "NO"
    ? ` for order ${draft.orderNumber}`
    : "";
  return (
    "Thank you for your patience — your issue has been submitted to our support team" +
    order +
    ". They will look into it and resolve it as soon as possible. Please wait for a response; " +
    "you'll be contacted on the phone number you provided.\n\n" +
    "Is there anything else I can help you with?"
  );
}

const PROVIDER_DIRECT_REPLY =
  "Sorry you're dealing with this. Let's get it to our team properly: tap " +
  "\"Submit an appeal\" below — it will be tagged with your provider context, " +
  "and the team reviews it right away.";
const FALLBACK_REPLY =
  "We're sorry your issue is still unresolved — our team has not yet responded to " +
  "your submitted ticket. To add details or evidence, submit an appeal below and " +
  "it will be linked to your case. We're sorry for the wait.";

// ── Quick-reply suggestions ──────────────────────────────────────────────
// Rendered by the app as tappable chips under the reply. The lists are short
// on purpose: a wall of buttons is a menu nobody reads, and the free-text box
// is always there for anything not listed. Every suggestion is phrased as
// something a PERSON would type, because tapping it sends it as their message.
const MAIN_SUGGESTIONS = [
  "What can you do?",
  "How do I track my order?",
  "How do payments work?",
  "I need to talk to a person",
];

const FALLBACK_SUGGESTIONS = [
  "How do I place an order?",
  "How do I book a ride?",
  "How does my wallet work?",
  "How do I contact support?",
];

const HELP_SUGGESTIONS = [
  "What is Aliob?",
  "How do I sign up?",
  "How do payments work?",
  "How do I change my notification settings?",
];

// Shown when nothing matched. It is NOT the old "submit an appeal" wall: the
// honest answer to an unparseable message is "I'm not sure yet — tell me a
// little more", plus a way out to a human. Escalation stays reserved for
// disputes and appeals, where the appeal form is actually the right door.
const NOT_UNDERSTOOD_REPLY =
  "Sorry, I'm not sure I understood that. Could you tell me a little more — " +
  "for example what you were trying to do, or which screen you were on?\n\n" +
  "Here are a few things I can help with right away. And if you'd rather have " +
  "a person look at it, tap \"Submit an appeal\" below and our team will pick " +
  "it up.";

const APOLOGY_REPLY =
  "I'm sorry — that sounds frustrating, and I'd like to help sort it out. " +
  "Tell me what happened (an order, a payment, a ride, or your account) and " +
  "I'll take you to the right place. If you'd prefer a person, I can send " +
  "this to our team instead.";

const HELP_REPLY =
  "Of course — I'm here to help 🙂 Here's what I can do:\n\n" +
  "• Explain how to sign up, sign in, or reset your password\n" +
  "• Walk you through buying, booking, or ordering a ride\n" +
  "• Explain fees, your wallet, and payments\n" +
  "• Help with notifications, privacy, or reporting something\n" +
  "• For providers: documents, listings, and staying active\n\n" +
  "Just describe your question in your own words.";

/** 10-hour no-response fallback: proactively hand out the direct contacts
 *  (once per ticket) when a user's submitted HELP_CHAT ticket has been OPEN
 *  with no admin response for 10+ hours. */
async function maybeGiveFallback(userId: string): Promise<string | null> {
  const tenHoursAgo = new Date(Date.now() - 10 * 60 * 60 * 1000).toISOString();
  const { data: tickets } = await admin
    .from("support_tickets")
    .select("id, created_at, resolved_at")
    .eq("user_id", userId)
    .eq("source", "HELP_CHAT")
    .in("status", ["OPEN", "IN_PROGRESS"])
    .lt("created_at", tenHoursAgo)
    .is("fallback_notified_at", null)
    .order("created_at", { ascending: false })
    .limit(5);
  const ticket = (tickets ?? [])[0] as { id: string } | undefined;
  if (!ticket) return null;
  const { error } = await admin
    .from("support_tickets")
    .update({ fallback_notified_at: new Date().toISOString() })
    .eq("id", ticket.id);
  if (error) {
    console.error("fallback_notified_at update failed:", error.message);
    return null;
  }
  return FALLBACK_REPLY;
}

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);
const embedder = new Supabase.ai.Session("gte-small");

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });

// ── Deep links: intent → in-app routes ───────────────────────────────────
// Every route here must exist in lib/features/help_chat/chat_deep_links.dart
// (the app validates/renders them as tappable chips under the reply).
const INTENT_ROUTES: Record<string, { label: string; route: string }[]> = {
  wallet_recharge: [
    { label: "Recharge my wallet", route: "/wallet/recharge" },
    { label: "Open my Wallet", route: "/wallet" },
  ],
  buying: [
    { label: "Browse & shop", route: "/user" },
    { label: "Open my cart", route: "/user/cart" },
  ],
  escrow: [],
  fees: [{ label: "Open my Wallet", route: "/wallet" }],
  rides: [{ label: "Book a ride", route: "/user/ride-request" }],
  provider_mode: [{ label: "Provider dashboard", route: "/provider" }],
  activation: [{ label: "Recharge my wallet", route: "/wallet/recharge" }],
  signup: [],
  points: [],
  ratings: [],
  // /user/orders is only a single order (/user/orders/:id). The orders LIST
  // is tab 2 of the /user shell — the old path was filtered out by the app's
  // known-route check, so the "My orders" chip never appeared at all.
  support: [{ label: "My orders", route: "/user?tab=1" }],
  ticket: [],
  balance: [
    { label: "Open my Wallet", route: "/wallet" },
    { label: "Recharge my wallet", route: "/wallet/recharge" },
  ],
  orders: [{ label: "My orders", route: "/user?tab=1" }],
  ride_status: [{ label: "Book a ride", route: "/user/ride-request" }],
  subscription: [{ label: "Open my Wallet", route: "/wallet" }],
  greeting: [],
  smalltalk: [],
  appeal: [{ label: "Submit an appeal", route: "/appeal" }],
  // Task 14: escalations carry context via query params — the appeal form
  // opens pre-tagged so the case lands with the right review context.
  // The /appeal route is validated in chat_deep_links.dart and handled by
  // AppealScreen (reads `about` + `source` from the query string).
  appeal_rider: [{ label: "Submit an appeal", route: "/appeal?about=rider&source=chat" }],
  appeal_provider: [{ label: "Submit an appeal", route: "/appeal?about=provider&source=chat" }],
  appeal_dispute: [{ label: "Submit an appeal", route: "/appeal?about=dispute&source=chat" }],
  appeal_account: [{ label: "Submit an appeal", route: "/appeal?about=account&source=chat" }],
  appeal_general: [{ label: "Submit an appeal", route: "/appeal?about=general&source=chat" }],
};

// Log the assistant turn server-side and return the response payload with
// deep links + the log id the app can attach thumbs feedback to.
async function respond(
  userId: string,
  reply: string,
  opts: {
    handoff?: boolean;
    intent?: string | null;
    // Optional override; defaults to INTENT_ROUTES[intent].
    links?: { label: string; route: string }[];
    // Tappable quick replies the app renders under the bubble. Sent as text
    // that is then submitted as the user's next message, so they must read
    // like something a person would type.
    suggestions?: string[];
  } = {},
): Promise<Response> {
  let logId = "";
  try {
    const { data } = await admin
      .from("chat_logs")
      .insert({
        user_id: userId,
        role: "assistant",
        content: reply,
        intent: opts.intent ?? null,
      })
      .select("id")
      .single();
    logId = (data as { id: string } | null)?.id ?? "";
  } catch (e) {
    console.error("chat_logs insert failed:", (e as Error).message);
  }
  return json({
    reply,
    handoff: opts.handoff === true,
    links: opts.links ?? ((opts.intent && INTENT_ROUTES[opts.intent]) || []),
    suggestions: opts.suggestions ?? [],
    log_id: logId,
  });
}

// ── Data-aware fast paths (the caller's live account status) ─────────────
// Reads go through the SECURITY DEFINER user_chat_context() RPC executed
// with the caller's JWT (auth.uid()), scoped strictly to that user.
interface ChatContext {
  is_provider: boolean;
  provider_status: string | null;
  wallet_balance: number | null;
  subscription: { status: string; next_due_date: string } | null;
  recent_orders: { status: string; total_amount: number }[] | null;
  active_ride: { status: string; created_at: string } | null;
}

async function loadChatContext(
  userClient: ReturnType<typeof createClient>,
): Promise<ChatContext | null> {
  try {
    const { data, error } = await userClient.rpc("user_chat_context");
    if (error) throw new Error(error.message);
    return (data ?? null) as ChatContext | null;
  } catch (e) {
    console.error("user_chat_context failed:", (e as Error).message);
    return null;
  }
}

const fmt = (n: number | null) =>
  n == null ? "unknown" : `${Number(n).toFixed(2)} ETB`;

const STATUS_WORDS: Record<string, string> = {
  CREATED: "created — waiting for payment verification",
  PENDING_PAYMENT: "waiting for payment verification",
  PAYMENT_VERIFIED: "payment verified — being prepared",
  CONFIRMED: "confirmed",
  SHIPPED: "on the way",
  DELIVERED: "delivered",
  COMPLETED: "completed",
  CANCELLED: "cancelled",
  REJECTED: "rejected",
  REQUESTED: "requested — looking for a driver",
  ACCEPTED: "accepted — your driver is on the way",
  IN_PROGRESS: "in progress",
  ARRIVED: "your driver has arrived",
};

const word = (s: string | null | undefined) =>
  s ? (STATUS_WORDS[s] ?? s.toLowerCase().replace(/_/g, " ")) : "unknown";

function dataReply(
  kind: string,
  ctx: ChatContext,
): { reply: string; intent: string } {
  switch (kind) {
    case "balance": {
      if (!ctx.is_provider) {
        return {
          reply:
            "Wallets belong to provider accounts — as a buyer you don't need one: each order is paid directly and held safely until delivery is confirmed. Is there anything else I can help you with?",
          intent: "balance",
        };
      }
      const low = ctx.wallet_balance != null && Number(ctx.wallet_balance) < 5;
      return {
        reply:
          `Your wallet balance is ${fmt(ctx.wallet_balance)}.` +
          (low
            ? " It's running low — recharge it so fees and your subscription never block your orders."
            : ""),
        intent: "balance",
      };
    }
    case "orders": {
      const orders = ctx.recent_orders ?? [];
      if (!orders.length) {
        return {
          reply:
            "You don't have any orders yet. Once you place one, ask me about its status any time and I'll tell you exactly where it stands.",
          intent: "orders",
        };
      }
      return {
        reply:
          "Your most recent orders:\n\n" +
          orders
            .map(
              (o, i) =>
                `${i + 1}. ${word(o.status)} — ${fmt(o.total_amount)}`,
            )
            .join("\n"),
        intent: "orders",
      };
    }
    case "ride": {
      if (!ctx.active_ride) {
        return {
          reply: "You have no active ride right now.",
          intent: "ride_status",
        };
      }
      return {
        reply: `Your current ride is ${word(ctx.active_ride.status)}. You can watch your driver move on the live map in the ride screen.`,
        intent: "ride_status",
      };
    }
    case "subscription": {
      const s = ctx.subscription;
      if (!s) {
        return {
          reply:
            "No subscription record yet — after your provider account is approved, the 5 Birr monthly subscription is deducted from your wallet automatically when it's due.",
          intent: "subscription",
        };
      }
      const due = s.next_due_date
        ? new Date(s.next_due_date).toISOString().slice(0, 10)
        : "unknown";
      return {
        reply: `Your monthly subscription is ${word(s.status)}; next payment due ${due}. It's deducted from your wallet automatically — keep a small balance so it never lapses.`,
        intent: "subscription",
      };
    }
    default:
      return { reply: "", intent: "" };
  }
}

// Status questions are answered from live data; phrased so how-to questions
// ("how do I recharge…?") still reach the canned guidance below.
const DATA_QUERY_RES: Record<string, RegExp> = {
  balance:
    /\b(balance|how\s+much\s+(money\s+)?(is\s+(in\s+)?my\s+wallet|do\s+i\s+have)|credit\s+left)\b/i,
  orders:
    /\b(order|parcel|delivery|purchase)\b.{0,20}\b(status|track|progress|update)\b|\b(track|status\s+of)\b.{0,20}\b(order|parcel|delivery|purchase)\b/i,
  ride:
    /\b(ride|trip|driver|taxi)\b.{0,20}\b(status|track|progress|arriving|on\s+the\s+way)\b|\b(track)\b.{0,20}\b(ride|driver|taxi)\b/i,
  subscription: /\b(subscription|monthly\s+(fee|payment|charge))\b/i,
};

function detectDataQuery(text: string): string | null {
  for (const [kind, re] of Object.entries(DATA_QUERY_RES)) {
    if (re.test(text)) return kind;
  }
  return null;
}

// ── Fast-path helpers ─────────────────────────────────────────────────────
const GREETING_RE =
  /^(hi|hii+|hello+|hay|hey+|hy|hallo|hiya|yo|selam|selamta|ሰላም|salam|hola|howdy|greetings|good\s+(morning|afternoon|evening|day)|whats?\s*up|what'?s\s*up|sup|how\s+(are|r)\s+(you|u)|how\s+are\s+you\s+doing|how\s+(are|is)\s+it\s+going|hows?\s+it\s+going|how'?s\s+it\s+going|nice\s+to\s+meet\s+you|good\s+to\s+see\s+you|good\s+(day|evening))[\s!.,?]*$/i;

function isGreeting(text: string): boolean {
  return GREETING_RE.test(text.trim());
}

// "repeat that" / "say that again". Handled in the request because the answer
// is the previous assistant turn, which only the request payload has.
const REPEAT_RE =
  /^(repeat|repeat\s+that|say\s+that\s+again|what\s+did\s+you\s+say|come\s+again|again\s+please|pardon|sorry\s+what)[\s!.,?]*$/;

function isRepeatRequest(text: string): boolean {
  return REPEAT_RE.test(text.trim());
}

// ── The greeting.
//
// This is not a hello. It is the only moment the assistant can save someone
// the work of describing their problem, so it names the reasons people
// actually open this chat and offers to route them. The list below is drawn
// from flows that EXIST in the app today -- every entry maps to a real screen
// or a real in-app form, and the footer names the entry points for each kind
// of account so nobody has to work out which one they are first.
//
// THREE VARIANTS, not one, because the greeting fires on every "hi" and a
// repeated wall of text stops being read. They differ in wording; they carry
// the same menu, because the menu is the point and round-robin must not be a
// lottery over what help is available.
//
// Kept to four lines of body text. A first-time user who is already frustrated
// does not read past the fold, and a menu longer than the screen is a wall.
const GREETING_BODY =
  "Pick whichever is closest — I'll take you straight to it:\n" +
  "•  **Verification or a rejection** — your documents, or why an application was turned down\n" +
  "•  **Appeal or report something** — a dispute, spam, fraud, or a suspension\n" +
  "•  **Payment or recharge delayed** — a recharge or order payment that hasn't landed\n" +
  "•  **An order or a ride problem** — wrong, missing, late, or a driver issue\n" +
  "•  **Your account** — profile, phone number, password, or closing your account\n\n" +
  "Not sure where you fit? Just describe it and I'll work it out.\n" +
  "_New here? Tip: ask me \"what can you do\" for the full list._";

const GREETING_REPLIES = [
  "Hi! 👋 I'm the Aliob assistant.\n\n" + GREETING_BODY,
  "Hello! 👋 Welcome to Aliob.\n\n" + GREETING_BODY,
  "Hi there! 😊 Tell me what's going on and I'll point you to the right place.\n\n" +
    GREETING_BODY,
];

// ── Small talk: friendly, varied, anchored so real questions are never
//    swallowed (each chatty pool matches the WHOLE message; the capabilities
//    pattern is safe anywhere because its reply is always relevant).
const CAPABILITIES_REPLY =
  "I'm the Aliob assistant 👋 Here's what I can help with:\n\n" +
  "• Buying & orders — how to shop, track an order, or a payment that's stuck\n" +
  "• Wallet & fees — recharges, the 1% fee, the 5 Birr subscription\n" +
  "• Rides — booking and live driver tracking\n" +
  "• Account — registering, activation, ratings\n" +
  "• Appeals — if you were flagged or want to report someone, I'll take you " +
  "to the appeal form\n\n" +
  "Ask me anything about the app!";

const SMALL_TALK_POOLS: { re: RegExp; replies: string[] }[] = [
  {
    re:
      /^(how'?s?|how\s+is)\s*(it\s*going|your\s*day|are\s*(you|u))([\s!,.?]*(and\s*(you|u))?)$|^how\s*(are|was)\s*(your|ur|the)\s*day([\s!,.?]*)?$|^(whats?|what'?s)\s*up[\s!,.?]*$/,
    replies: [
      "I'm doing great, thanks for asking! 😊 How can I help you today?",
      "All good on my side! What can I do for you?",
      "Having a good day so far — how about you? Anything I can help with?",
    ],
  },
  {
    re: /\b(who\s*are\s*(you|u)|are\s*(you|u)\s*(a\s*)?(robot|bot|ai|human)|what\s*can\s*(you|u)\s*(do|help)|what\s*do\s*you\s*(do|know)|what\s+is\s+your\s+name|how\s+do\s+you\s+work|are\s+you\s+real|do\s+you\s+(?:sleep|eat|rest)|who\s+(?:made|created|built|programmed)\s+you|what\s+are\s+you\b|your\s*name)\b/,
    replies: [CAPABILITIES_REPLY],
  },
  {
    // Apology and frustration. Deliberately anchored to the WHOLE message: a
    // real complaint ("this is bad, my order never arrived") carries detail
    // and must keep flowing to the ticket/escalation path instead of being
    // answered with sympathy and no action.
    re: /^(sorry|so\s+sorry|i\s*am\s+sorry|im\s+sorry|my\s+bad|apologies|apologise|i\s+apologize|this\s+is\s+(bad|terrible|awful|useless|rubbish|frustrating|unacceptable|not\s+good)|its\s+(bad|terrible|awful|useless)|that\s+is\s+(bad|terrible|awful|useless)|i\s*am\s+(angry|upset|frustrated|annoyed|disappointed|mad)|im\s+(angry|upset|frustrated|annoyed|disappointed|mad)|so\s+(angry|frustrated|annoyed)|very\s+(bad|disappointing)|worst\s+(app|service|experience)|not\s+good|this\s+sucks|unacceptable)[\s!.,?]*$/,
    replies: [
      APOLOGY_REPLY,
      "I'm really sorry about that — let's get it fixed. Can you tell me a little " +
        "more about what went wrong? If you'd rather speak to a person, the " +
        "appeal form below goes straight to our team.",
    ],
  },
  {
    // Bare "help" / "I need a person". Answered with a menu instead of being
    // pushed through retrieval and landing on an appeal form.
    re: /^(help|help\s+me|i\s+need\s+help|need\s+help|can\s+you\s+help(\s+me)?|assist\s+me|i\s+need\s+(some\s+)?support|support|talk\s+to\s+(a\s+)?(human|person|agent)|human|agent|support\s+please)[\s!.,?]*$/,
    replies: [HELP_REPLY],
  },
  {
    // "Repeat that" with no history to repeat (a fresh conversation, or the
    // server isolate changed). The handler echoes the real previous answer
    // when it has one; this is the honest fallback.
    re: /^(repeat|repeat\s+that|say\s+that\s+again|what\s+did\s+you\s+say|come\s+again|again\s+please|pardon|sorry\s+what)[\s!.,?]*$/,
    replies: [
      "Of course — could you tell me which part you'd like again? I can also " +
        "start over: just ask me anything about Aliob.",
    ],
  },
  {
    re: /^(thanks?|ty|appreciate\s*it|much\s+appreciated|appreciated|thanks?\s+again|no\s+worries|np|cheers|great|perfect|awesome|nice\s*one|well\s*done|good\s*(job|work)|great\s*(job|work)|nice\s*(job|work)|excellent)[\s!,.]*$/,
    replies: [
      "You're very welcome! 😊 Anything else I can help with?",
      "Happy to help! Is there anything else?",
      "Anytime! Let me know if you need anything else.",
    ],
  },
  {
    re: /^(bye|bye\s*bye|goodbye|see\s*(you|ya)(\s+(tomorrow|soon|later|around|then))?|later|catch\s+(you|ya)\s+later|talk\s+to\s+you\s+later|ttyl|take\s+care|good\s*night|gn|good\s*day)[\s!,.]*$/,
    replies: [
      "Goodbye! 👋 Come back any time you need help.",
      "See you! Have a great day. 😊",
    ],
  },
  {
    // The user reporting they're fine — the natural answer to the
    // assistant's own "how are you?". Optional "and you" tail folded in.
    re: /^(?:im|i\s+am|i\s+m|am|feeling|its|it\s+is)?\s*(?:fine|good|great|okay|ok|well|alright|not\s+bad|pretty\s+good|very\s+good|doing\s+(?:good|great|fine|well|okay)|cant\s+complain|asleep|alive)[\s!.,?]*(?:and\s+(?:you|u))?[\s!.,?]*$/,
    replies: [
      "Glad to hear it! 😊 What can I help you with today?",
      "Happy to hear that! Anything I can help you with?",
    ],
  },
  {
    // Return-question: the user bounces the “how are you?” back.
    re: /^(and\s+(?:you|u)|wbu|hbu|you\?|u\?)[\s!.,?]*$/,
    replies: [
      "I'm doing great, thanks! 😊 More importantly — what can I help you with?",
    ],
  },
  {
    re: /^(ok|okay|okay\s+good|alright|cool|nice|hmm+|oh+i+see|okey|k|kk|got\s*it|i\s*see|understood|makes\s+sense|sounds\s+good|that\s+helps|nice\s+to\s+hear|noted|copy\s*that|roger|will\s+do|sure\s+thing|fine|good|yes|yeah|yep|yup|sure|no|nope|nah|true|right|exactly|absolutely|definitely|of\s+course)[\s!.,?]*$/,
    replies: [
      "Is there anything else I can help you with?",
      "Anything else you'd like to know?",
    ],
  },
];

const smallTalkCounters = new Map<string, number>();

function pickReply(userId: string, pool: string[]): string {
  if (smallTalkCounters.size > 500) smallTalkCounters.clear();
  const i = smallTalkCounters.get(userId) ?? 0;
  smallTalkCounters.set(userId, i + 1);
  return pool[i % pool.length] ?? pool[0] ?? GREETING_REPLIES[0];
}

function smallTalkReply(userId: string, q: string): string | null {
  for (const t of SMALL_TALK_POOLS) {
    if (t.re.test(q)) return pickReply(userId, t.replies);
  }
  return null;
}

// ── Canned answers for the app's core flows ──────────────────────────────
// Deliberately short, conversational, and honest — the FAQ doc holds the
// long-form versions and remains the retrieval source of truth.
const CANNED_TOPICS: { patterns: RegExp; reply: string }[] = [
  // ── The questions a new user actually asks first ────────────────────────
  // These sit ABOVE the flow topics on purpose: "how do I cancel my order"
  // contains "order", so the generic buying answer would otherwise swallow it.
  {
    patterns:
      /\b(what\s+is\s+aliob|what\s+is\s+this\s+app|what\s+does\s+aliob\s+do|about\s+aliob|what\s+can\s+i\s+do\s+(here|on\s+(this|the)\s+app)|what\s+is\s+(the\s+)?app\s+for|explain\s+aliob)\b/i,
    reply:
      "Aliob (All In One Business) is an Ethiopian marketplace app that brings " +
      "shopping and services into one place.\n\n" +
      "• Customers browse products and services near them, place orders, book " +
      "services, and request rides.\n" +
      "• Providers — shops, vehicle owners and service providers — list what " +
      "they offer, answer availability questions, and manage orders from their " +
      "dashboard.\n" +
      "• Payments are made by transfer (bank or Telebirr) and the screenshot is " +
      "verified before an order moves forward, so both sides are protected.\n\n" +
      "You can chat with the provider inside the app, and the help chat you are " +
      "using now can answer questions about any of it.",
  },
  {
    patterns:
      /\b(sign\s*in|log\s*in|login|forgot\s+(my\s+)?password|reset\s+(my\s+)?password|change\s+(my\s+)?password|password\s+(not\s+working|wrong|reset)|cant\s+(sign|log)\s*in|cannot\s+(sign|log)\s*in|locked\s+out|account\s+locked|cant\s+remember\s+my\s+password)\b/i,
    reply:
      "Signing in and passwords:\n\n" +
      "• Sign in with the email and password you registered with, or tap " +
      "Continue with Google if that is how you joined.\n" +
      "• Forgot your password? Tap \"Forgot password\" on the sign-in screen and " +
      "we'll email you a secure link to set a new one.\n" +
      "• To change it while signed in: Profile → Change Password. You'll be " +
      "asked for your current password first.\n" +
      "• After several wrong attempts, sign-in pauses for a short while. Wait a " +
      "few minutes and try again, then reset the password if it still fails.\n\n" +
      "For your safety, never share your password or the reset link with anyone " +
      "— including anyone claiming to be from Aliob.",
  },
  {
    patterns:
      /\b(cancel\s+(my\s+)?(order|booking|ride)|refunds?|money\s+back|order\s+status|status\s+of\s+my\s+order|track\s+(my\s+)?order|where\s+is\s+my\s+order|how\s+long\s+does\s+(an\s+)?order\s+take|order\s+stuck|order\s+not\s+moving)\b/i,
    reply:
      "Orders, cancellations and refunds:\n\n" +
      "• Your order's status is shown in My Orders — tap the order to see its " +
      "history, from payment verification through to completion.\n" +
      "• You can cancel from the order screen while the order is still open. " +
      "Once a payment is being verified, only our team can cancel it — use the " +
      "help form and they will handle it.\n" +
      "• If something is wrong with a delivered order, or you are owed money " +
      "back, send it through the appeal form below. Refunds are decided case by " +
      "case after the team reviews the order, and the outcome is sent to you in " +
      "the app — I can't promise a fixed number of days.\n\n" +
      "A provider who is not responding is worth reporting: the team can see the " +
      "order and step in.",
  },
  {
    patterns:
      /\b(notifications?|notification\s+settings|push\s+(notification|message)|turn\s+(off|on)\s+notifications|stop\s+(the\s+)?notifications|unread|inbox|badge)\b/i,
    reply:
      "Notifications:\n\n" +
      "• Important events (an order update, a payment verification, a ride, a " +
      "document decision) arrive as a push notification and are saved in your " +
      "in-app inbox, so you can look back at them later.\n" +
      "• To change what you receive: Profile → Notification Settings. You can " +
      "turn push on or off there; the SMS and email switches are saved for when " +
      "those channels launch.\n" +
      "• If Android asks for notification permission, allow it — without it the " +
      "app cannot alert you, though your inbox still fills up.",
  },
  {
    patterns:
      /\b(privacy|is\s+(my|the)\s+(data|information)\s+safe|data\s+(safe|protection)|share\s+my\s+(phone|number|details)|who\s+can\s+see\s+my|terms\s+(and|&)\s+privacy|gdpr|delete\s+my\s+(data|account)|close\s+my\s+account)\b/i,
    reply:
      "Your privacy and safety:\n\n" +
      "• Your ID document and payment screenshots are used to verify your " +
      "account and orders, and are reviewed by our team — they are not shown to " +
      "other users.\n" +
      "• A provider's contact details and live location are shared with you only " +
      "after your payment is confirmed, and location sharing for a ride ends " +
      "when the ride does.\n" +
      "• The full Terms & Privacy Policy is in Profile → About Aliob → Terms & " +
      "Privacy Policy.\n" +
      "• To close your account: Profile → Delete Account. It sends a request to " +
      "our team, who process it — past orders are kept for accounting records.\n\n" +
      "Never share your password, a one-time code, or your full ID number with " +
      "anyone in chat — Aliob will never ask for them.",
  },
  {
    patterns:
      /\b(contact\s+(support|you|us|the\s+team)|talk\s+to\s+(a\s+)?(human|person|agent|someone)|human\s+(support|help)|customer\s+(service|support)|speak\s+to\s+(a\s+)?(person|human)|real\s+person|support\s+team)\b/i,
    reply:
      "Reaching a person:\n\n" +
      "• The fastest route is the appeal form below — it reaches our team with " +
      "your account attached, and you can add details and photos.\n" +
      "• For an order or payment problem, keep the order number handy (it looks " +
      "like Vh00012 or Fd00007); it helps the team find the case immediately.\n" +
      "• Replies arrive in the app — as a notification and in your inbox — so " +
      "you don't need to wait in this chat.\n\n" +
      "Aliob support does not ask for your password, a one-time code, or your " +
      "full ID number. If anyone does, stop and report it here.",
  },
  // ── Provider questions ──────────────────────────────────────────────────
  {
    patterns:
      /\b(documents?|my\s+id|national\s+id|driving\s+licen[cs]e|trade\s+licen[cs]e|upload\s+(my\s+)?(id|document|licen[cs]e)|verif(y|ication)\s+(my\s+)?(account|document|id)|document\s+(approved|rejected)|kyc)\b/i,
    reply:
      "Documents and verification:\n\n" +
      "• Upload your documents from your profile (the verification section), or " +
      "when the app asks during sign-up.\n" +
      "• A national ID is expected for every account. Vehicle providers also " +
      "upload a driving licence; service providers a trading licence.\n" +
      "• Our team reviews each document and you get a notification with the " +
      "decision. If one is rejected, the message says why and you can upload a " +
      "clearer copy.\n" +
      "• While something is still pending, your dashboard tells you what is " +
      "blocked and what you can already do.\n\n" +
      "Take the photo in good light, with all four corners visible and no glare.",
  },
  {
    patterns:
      /\b(?:post|add|upload|create|list)\s+(?:a\s+|my\s+)?(?:product|listing|item|vehicle|service)|\bhow\s+do\s+i\s+(?:sell|list)\s+(?:a\s+)?(?:product|item|vehicle|service)|\bnew\s+listing|\bmanage\s+my\s+listings/i,
    reply:
      "Posting a listing:\n\n" +
      "1. Open your provider dashboard and go to your products (or vehicles for " +
      "ride providers).\n" +
      "2. Tap Add New and fill in the name, category, price and description.\n" +
      "3. Add clear photos — listings with a real photo are the ones buyers tap.\n" +
      "4. Publish. You can hide or edit a listing at any time from the same " +
      "screen.\n\n" +
      "If publishing is blocked, the app tells you why on the dashboard: usually " +
      "the account is not activated yet (the first recharge includes the " +
      "one-time registration fee) or the wallet is empty, because fees are " +
      "deducted from it.",
  },
  {
    patterns:
      /\b(get\s+(more\s+)?customers|more\s+(sales|orders|buyers)|stay\s+active|keep\s+my\s+account\s+active|why\s+am\s+i\s+not\s+getting\s+orders|no\s+orders|grow\s+my\s+business|subscription\s+lapsed)\b/i,
    reply:
      "Getting and keeping customers:\n\n" +
      "• Answer availability requests quickly — a buyer asks before checkout, " +
      "and the request expires if nobody replies, so a fast answer wins the " +
      "sale.\n" +
      "• Keep your wallet funded: the monthly subscription and order fees are " +
      "deducted from it, and an empty wallet stops new orders being accepted.\n" +
      "• Keep listings current — real photos, correct price, and hide what is " +
      "out of stock.\n" +
      "• Complete orders and collect ratings; the stars, completed sales and " +
      "completion rate on your profile all come from real orders.\n\n" +
      "If your account shows as suspended, the dashboard says what is needed to " +
      "restore it.",
  },
  // ── Customer flows ──────────────────────────────────────────────────────
  {
    patterns:
      /\b(deliver(y|ed)?|do\s+you\s+deliver|shipping|bring\s+it\s+to\s+me|courier)\b/i,
    reply:
      "Delivery:\n\n" +
      "• Order from a provider as usual, then arrange delivery with them in the " +
      "in-app chat — many providers deliver themselves.\n" +
      "• The delivery cost depends on the provider and the distance, so it is " +
      "confirmed with them (and shown before you confirm) rather than guessed " +
      "here.\n" +
      "• Once the order is paid and confirmed, the provider's contact details " +
      "and location become available so the two of you can coordinate.\n\n" +
      "If a delivery never arrives, report it from the order — the team can see " +
      "the whole order and step in.",
  },
  // Rooms, services and appointments. The negative lookahead keeps "how do I
  // book a RIDE" on the rides topic below: answering a ride question with the
  // service-booking steps was a real mismatch.
  {
    patterns:
      /^(?!.*\bride\b).*\b(book(ing)?\s+(a\s+)?(room|service|appointment|hotel|table|place)|reserv(e|ation)|how\s+do\s+i\s+book|book\s+(a\s+)?service|schedule\s+(a\s+)?(service|appointment))\b/i,
    reply:
      "Booking a service:\n\n" +
      "1. Open the service or room you want and choose Buy/Book.\n" +
      "2. If the provider needs to confirm availability, the app sends them your " +
      "request and they answer in a short window — you'll see the answer right " +
      "away.\n" +
      "3. Continue to checkout, upload your payment screenshot, and the order " +
      "moves forward once the payment is verified.\n\n" +
      "The price is shown before you confirm, and every booking gets its own " +
      "order number you can quote to support.",
  },
  // ── Existing flow topics ────────────────────────────────────────────────
  {
    patterns:
      /\b(sign\s*up|register|registration|create\s+(an?\s+)?(account|acct)|open\s+(an?\s+)?account|join\s+the\s+app|become\s+(a\s+)?(seller|provider|driver|user)|how\s+(do|can)\s+i\s+(sell|provide\s+rides)|get\s+started)\b/i,
    reply:
      "Creating an account is easy:\n\n" +
      "1. Tap Get Started on the home screen and pick your account type — personal, vehicle provider, or service provider.\n" +
      "2. Fill in your details and upload a photo of your national ID (vehicle providers also need a driving license; service providers a trading license).\n" +
      "3. Read and accept the Terms & Privacy Policy — the checkbox on the form.\n" +
      "4. Our team reviews every application — usually quickly — and you'll get a notification once you're approved.\n\n" +
      "Anything else you'd like to know?",
  },
  {
    patterns: /\b(buy|buying|purchase|order|orders|shop|shopping|add\s+to\s+cart|cart|checkout|check\s+out|place\s+an?\s+order)\b/i,
    reply:
      "To buy something:\n\n" +
      "1. Browse or search for a product and open it.\n" +
      "2. Add it to your cart — you can mix items from different sellers; each seller's items check out as a separate order.\n" +
      "3. Check out and upload your payment screenshot. For your first booking you'll also be asked for a photo of your National ID.\n\n" +
      "Every order gets its own number (like Vh00012 for vehicles, Ht00003 for household goods, Fd00007 for food) so it's easy to reference. Once our team verifies the payment, the order moves forward and the seller is notified.\n\n" +
      "Want help with anything specific?",
  },
  {
    patterns: /\b(escrow|payment\s+(verification|proof|confirm)|is\s+(it|my\s+(payment|money))\s+safe|hold\s+(my\s+)?(money|payment)|protected|scam|fraud|trust)\b/i,
    reply:
      "Your payment is held safely (escrow) until the order is confirmed:\n\n" +
      "• You upload your payment screenshot at checkout.\n" +
      "• Our team verifies it — only then does the order move forward.\n" +
      "• The seller's contact and live location are shared with you only after your payment is confirmed, so details stay private on purpose.\n" +
      "• You can chat inside the app the whole time, and share your live location with the seller once payment is confirmed.\n\n" +
      "This protects both sides of every deal.",
  },
  {
    patterns: /\b(recharge|top\s*up|topup|wallet|telebirr|deposit\s+money|add\s+(money|funds|balance)|credit\s+my\s+wallet|pay\s+(the\s+)?(monthly|subscription|fee))\b/i,
    reply:
      "Wallet recharge (providers):\n\n" +
      "1. Open Wallet from your provider dashboard and tap RECHARGE WALLET.\n" +
      "2. Send the amount to our Telebirr account: 0917686990 (Aliob Business).\n" +
      "3. Enter the amount, the transaction reference, and upload your payment screenshot.\n" +
      "4. Once an admin verifies it, your wallet is credited.\n\n" +
      "Note: your FIRST recharge includes a one-time {{registration_fee}} birr registration fee that activates your account — so your first recharge must be at least {{registration_fee}} birr (anything above the fee is credited to your wallet). After that, recharges are credited in full.\n\n" +
      "Your wallet then automatically covers the transaction fee on sales and the monthly subscription when it's due.",
  },
  {
    patterns: /\b(points?|rewards?|loyalty|earn\s+points)\b/i,
    reply:
      "Points:\n\n" +
      "• Every successfully completed sale earns the provider points automatically.\n" +
      "• Buyers earn points for completed orders too.\n" +
      "• Your points total is shown on your dashboard and profile.\n\n" +
      "No setup needed — points just accumulate as you use the app.",
  },
  {
    patterns: /\b(fees?|charges?|commission|costs?|1\s*%|five\s*birr|5\s*birr|how\s+much\s+(does\s+it\s+cost|do\s+you\s+charge|is\s+the\s+fee))\b/i,
    reply:
      "Fees:\n\n" +
      "• Orders include a small transaction fee — about {{fee_percent}}% of the amount, with a minimum of {{fee_min}} birr — shown clearly at checkout before you pay.\n" +
      "• Providers pay a fixed {{subscription_fee}} Birr monthly subscription after their account is approved.\n" +
      "• Providers also pay a one-time {{registration_fee}} birr registration fee with their first recharge to activate their account.\n" +
      "• All fees are deducted automatically from your provider wallet — no hidden charges.\n\n" +
      "If your wallet runs low (or is empty), recharging it from your dashboard keeps orders flowing.",
  },
  {
    patterns: /\b(rides?|taxi|driver|trip|trips|vehicle)\b/i,
    reply:
      "Rides:\n\n" +
      "• Pick your pickup point on the ride screen — the app fills it in automatically if you allow location access.\n" +
      "• A nearby driver accepts your request, and once they claim it you can watch their vehicle move on the map in real time.\n" +
      "• You can share your live location with your driver for that ride only, and tap Get directions to navigate to them.\n\n" +
      "Location sharing between you and the driver ends when the ride ends.",
  },
  {
    patterns: /\b(browse\s+&\s+shop|browse\s+and\s+shop|browse\s*&\s*shop|provider\s+(mode|dashboard|account)|shop\s+as\s+(a\s+)?provider|buy\s+as\s+(a\s+)?provider|switch\s+(to\s+)?(buyer|shopping)|sell\s+and\s+buy)\b/i,
    reply:
      "Provider accounts can do both:\n\n" +
      "• Your provider dashboard is where you manage your business — listings, orders, wallet, and vehicles.\n" +
      "• Tap Browse & Shop on your dashboard to switch into the buyer experience and order from other providers exactly like a regular user.\n\n" +
      "Your business view stays exactly as it is — shopping is added on top.",
  },
  {
    patterns: /\b(activat(e|ion)|registration\s+fee|can'?t\s+(upload|list|add)\s+(a\s+)?(product|listing|vehicle)|can'?t\s+(accept|receive)\s+orders?|not\s+activated|account\s+activation|first\s+recharge|why\s+can'?t\s+i\s+(sell|list))\b/i,
    reply:
      "Account activation (providers):\n\n" +
      "After your account is approved, one step remains: pay the one-time 100 birr registration fee with your first wallet recharge.\n\n" +
      "• Until then you can't upload listings or receive orders.\n" +
      "• Your first recharge must be at least 100 birr — the fee activates your account and the rest is credited to your wallet.\n" +
      "• Once it's approved you're fully activated: upload listings, accept orders, and reveal your location to buyers.\n\n" +
      "Keep a small wallet balance too — orders can't be accepted when the balance is 0, because fees are deducted from the wallet.",
  },
  {
    patterns: /\b(ratings?|reviews?|stars?|feedback|rate\s+(a\s+)?(seller|provider|driver))\b/i,
    reply:
      "Ratings and reviews:\n\n" +
      "• After an order is completed you can rate the seller.\n" +
      "• Ratings feed the average stars, completed sales, and completion rate shown on the seller's profile — all from real orders.\n\n" +
      "Honest ratings keep the marketplace trustworthy for everyone.",
  },
];

/**
 * Live fee numbers for the assistant's answers.
 *
 * These used to be prose baked into the strings above, which meant the
 * assistant could quote a fee the CEO had already changed — it would answer
 * "100 birr registration" confidently while the wallet charged something else.
 * Read from system_settings, which is the same source the charges read.
 *
 * Cached for five minutes: a fee change is rare, this runs on every chat turn,
 * and a stale-by-minutes answer is not a correctness problem the way a
 * hardcoded one was.
 */
type FeeFacts = {
  registrationFee: number;
  subscriptionFee: number;
  feePercent: number;
  feeMin: number;
};

// Mirrors the seeded defaults, so a settings outage degrades to sensible
// numbers instead of to no answer at all.
const FEE_FACT_FALLBACK: FeeFacts = {
  registrationFee: 100,
  subscriptionFee: 5,
  feePercent: 1,
  feeMin: 5,
};

let feeFactsCache: { at: number; facts: FeeFacts } | null = null;
const FEE_FACT_CACHE_MS = 5 * 60 * 1000;

async function feeFacts(): Promise<FeeFacts> {
  if (feeFactsCache && Date.now() - feeFactsCache.at < FEE_FACT_CACHE_MS) {
    return feeFactsCache.facts;
  }
  try {
    const { data } = await admin.from("system_settings").select("key,value").like("key", "%fee%");
    const byKey = new Map<string, number>();
    for (const row of data ?? []) {
      const raw = row.value as unknown;
      const n = typeof raw === "number" ? raw : Number(raw);
      if (Number.isFinite(n)) byKey.set(row.key as string, n);
    }
    const subscriptionKey = [...byKey.keys()].find((k) => k.includes("subscription"));
    const facts: FeeFacts = {
      registrationFee: byKey.get("provider_registration_fee") ?? FEE_FACT_FALLBACK.registrationFee,
      subscriptionFee:
        byKey.get("provider_subscription_fee") ??
        (subscriptionKey ? byKey.get(subscriptionKey)! : FEE_FACT_FALLBACK.subscriptionFee),
      feePercent: byKey.get("transaction_fee_percent") ?? FEE_FACT_FALLBACK.feePercent,
      feeMin: byKey.get("transaction_fee_min") ?? FEE_FACT_FALLBACK.feeMin,
    };
    feeFactsCache = { at: Date.now(), facts };
    return facts;
  } catch {
    return FEE_FACT_FALLBACK;
  }
}

/** Substitute the fee placeholders in a canned answer with live values. */
async function applyFeeFacts(reply: string): Promise<string> {
  if (!reply.includes("{{")) return reply;
  const facts = await feeFacts();
  return reply
    .replaceAll("{{registration_fee}}", String(facts.registrationFee))
    .replaceAll("{{subscription_fee}}", String(facts.subscriptionFee))
    .replaceAll("{{fee_percent}}", String(facts.feePercent))
    .replaceAll("{{fee_min}}", String(facts.feeMin));
}

/// One extra sentence for people who are already providers.
///
/// The role is read from user_roles (loadProviderContext), not guessed from
/// the wording, so it is right even when the question is a generic one. Kept
/// short and only on the topics where the provider view genuinely differs.
function providerTail(intent: string | null): string {
  switch (intent) {
    case "fees":
    case "wallet_recharge":
      return "\n\nAs a provider, Wallet on your dashboard is where you recharge — order " +
        "fees and the monthly subscription are deducted from that balance.";
    case "activation":
    case "post_listing":
      return "\n\nYour provider dashboard shows the activation state and exactly " +
        "what is still needed before you can publish.";
    case "stay_active":
      return "\n\nYour dashboard brings the three things that matter into one " +
        "place: availability requests, wallet balance, and listings.";
    case "order_help":
      return "\n\nAs a provider you can also see incoming orders and answer " +
        "availability requests from your dashboard.";
    default:
      return "";
  }
}

async function cannedReply(text: string, isProvider = false): Promise<string | null> {
  for (let i = 0; i < CANNED_TOPICS.length; i++) {
    if (!CANNED_TOPICS[i].patterns.test(text)) continue;
    const base = await applyFeeFacts(CANNED_TOPICS[i].reply);
    return isProvider ? base + providerTail(CANNED_NAMES[i] ?? null) : base;
  }
  return null;
}

// Intent keys for chat_logs, aligned by index with CANNED_TOPICS above.
// Keep both arrays in the same order.
const CANNED_NAMES = [
  "what_is_aliob",
  "login",
  "order_help",
  "notifications",
  "privacy",
  "support",
  "provider_docs",
  "post_listing",
  "stay_active",
  "delivery",
  "booking",
  "signup",
  "buying",
  "escrow",
  "wallet_recharge",
  "points",
  "fees",
  "rides",
  "provider_mode",
  "activation",
  "ratings",
];

function cannedIntent(text: string): string | null {
  for (let i = 0; i < CANNED_TOPICS.length; i++) {
    if (CANNED_TOPICS[i].patterns.test(text)) return CANNED_NAMES[i] ?? null;
  }
  return null;
}

// ── Human handoff (returned whenever the agent can't help) ───────────────
// Task 14: NO contact details, ever. The in-app appeal flow IS the handoff.
function handoffReply(ctx: AppealContext = { about: "general" }): string {
  return escalationReply(ctx);
}

// Keyword fallback for short/keyword-style queries that embedding search
// scores weakly. Same corpus, same kinds filter, service-role only — the
// security guarantees are identical to the semantic path.
async function searchKeywords(q: string, matchCount: number) {
  const cleaned = q.replace(/[^\p{L}\p{N}\s]/gu, " ").trim();
  if (!cleaned) return [] as { content: string; score: number }[];
  const words = cleaned.split(/\s+/).filter((w) => w.length >= 4).slice(0, 5);
  if (!words.length) return [] as { content: string; score: number }[];
  try {
    const orFilter = words.map((w) => `content.ilike.%${w}%`).join(",");
    const { data, error } = await admin
      .from("repo_chunks")
      .select("content")
      .in("kind", ["doc", "ui_text"])
      .or(orFilter)
      .limit(matchCount);
    if (error) {
      console.error("searchKeywords failed:", error.message);
      return [] as { content: string; score: number }[];
    }
    // Constant modest score keeps the buildAnswer threshold logic intact.
    return ((data ?? []) as { content: string }[]).map((row) => ({
      content: row.content,
      score: 0.02,
    }));
  } catch (e) {
    console.error("searchKeywords failed:", (e as Error).message);
    return [] as { content: string; score: number }[];
  }
}

// Search ONLY docs and UI text so end users never see code, file paths or table names.
async function search(query: string, matchCount: number) {
  const emb = await embedder.run(query, { mean_pool: true, normalize: true });
  const { data, error } = await admin.rpc("match_chunks", {
    query_embedding: JSON.stringify(Array.from(emb)),
    query_text: query,
    match_count: matchCount,
    kinds: ["doc", "ui_text"],
  });
  if (error) {
    console.error("match_chunks failed:", error.message);
    return [] as { content: string; score: number }[];
  }
  return (data ?? []) as { content: string; score: number }[];
}

// Indexer chunks carry a "File: <path>" header; strip it so paths never reach users.
function stripFileHeader(content: string): string {
  return content.replace(/^File:\s*.*$/m, "").trim();
}

function looksLikeInternalPath(s: string): boolean {
  return /(^|[\s(])[\w./-]+\.(dart|ts|sql|mjs|arb)\b/i.test(s) || /\b(lib|supabase|tools)\//.test(s);
}

// Minimum retrieval score before we trust a retrieved answer. The hybrid
// score is rank-based, so a single top-20 semantic hit alone scores ~0.0164;
// a keyword match alone ~0.0164; both together ~0.0328. Anything weaker than
// one meaningful match is treated as "not found" → human handoff.
const MIN_HIT_SCORE = 0.012;

function buildAnswer(
  query: string,
  hits: { content: string; score: number }[],
): { reply: string; handoff: boolean } {
  const good = hits.filter((h) => h.score >= MIN_HIT_SCORE);
  const top = good.slice(0, 3).map((h) => stripFileHeader(h.content)).filter(Boolean);
  if (!top.length) return { reply: handoffReply(), handoff: true };
  if (top.some((t) => looksLikeInternalPath(t))) return { reply: handoffReply(), handoff: true };
  return { reply: top.join("\n\n"), handoff: false };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  // 1. Auth: only signed-in app users.
  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
  );
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "unauthorized" }, 401);

  // 2. Rate limit.
  const { data: used } = await admin.rpc("bump_usage", { p_user: user.id });
  if ((used ?? 0) > DAILY_LIMIT) return json({ error: "daily_limit" }, 429);

  // 3. Parse the latest user message (keep the request shape compatible).
  const body = await req.json().catch(() => ({}));
  const msgs = (Array.isArray(body.messages) ? body.messages : [])
    .filter((m: any) => (m?.role === "user" || m?.role === "assistant") && typeof m.content === "string")
    .slice(-10)
    .map((m: any) => ({ role: m.role, content: String(m.content).slice(0, 2000) }));
  while (msgs.length && msgs[0].role !== "user") msgs.shift();
  if (!msgs.length) return json({ error: "no_message" }, 400);
  const question = msgs[msgs.length - 1].content.trim();
  if (!question) return json({ error: "no_message" }, 400);

  try {
    if (LLM_PROVIDER !== "none") return json({ error: "unsupported_provider" }, 400);

    // 4a. Fast path: greetings, small talk, and appeal/spam-report intent.
    // Greetings answer at any time (original behavior — including mid-ticket-
    // flow); the other small-talk tiers stand down while a guided ticket flow
    // owns the exchange, so its questions are never hijacked by a terse
    // "ok"/"thanks" answer.
    rememberMessage(user.id, question);
    const nq = norm(question);
    const session = getSession(user.id);
    // Who is speaking (provider vs regular user) — computed once, used by
    // both the Task 14 escalation classifier and the ticket-flow branch.
    const providerCtx = await loadProviderContext(user.id);
    if (isGreeting(nq)) {
      return respond(user.id, pickReply(user.id, GREETING_REPLIES), {
        intent: "greeting",
        suggestions: MAIN_SUGGESTIONS,
      });
    }
    // "repeat that" — echo the last assistant answer verbatim (the client
    // sends the history, so the text is right here). Without history, the
    // small-talk pool below asks which part, which is the honest answer.
    if (isRepeatRequest(nq)) {
      const lastAnswer = [...msgs]
        .reverse()
        .find((m: { role: string }) => m.role === "assistant")?.content;
      if (lastAnswer) {
        return respond(user.id, `Of course — here it is again:\n\n${lastAnswer}`, {
          intent: "repeat",
        });
      }
    }
    if (!session) {
      const talk = smallTalkReply(user.id, nq);
      if (talk) {
        const suggestions = talk === HELP_REPLY
          ? HELP_SUGGESTIONS
          : talk === CAPABILITIES_REPLY
          ? MAIN_SUGGESTIONS
          : talk === APOLOGY_REPLY
          ? FALLBACK_SUGGESTIONS
          : [];
        return respond(user.id, talk, {
          intent: "smalltalk",
          suggestions,
        });
      }
      // Appeal/spam-report intent AND dispute/scam/fraud/account/rider
      // shapes escalate straight to the Appeal Page (Task 14) — classified
      // by who is speaking so the form opens pre-tagged. Plain
      // "other party not responding" complaints still take the guided
      // ticket flow below (its structured questions feed support_tickets,
      // which the CEO/assigned staff answer) — both channels are in-app,
      // and neither ever emits contact details.
      const appealCtx = classifyAppeal(nq, providerCtx.isProvider);
      const needsEscalation =
        isAppealIntent(nq) ||
        isDisputeIntent(nq) ||
        isAccountIntent(nq) ||
        (isComplaintIntent(nq) && isRiderIntent(nq));
      if (needsEscalation) {
        clearSession(user.id); // a fresh escalation never resumes a stale draft
        const intent = `appeal_${appealCtx.about}`;
        return respond(user.id, appealReply(), {
          intent,
          links: INTENT_ROUTES[intent],
        });
      }
    }

    // 4a-bis. Live-data questions answered from the caller's own account
    // (wallet balance, order/ride status, subscription) — read-only, scoped
    // to auth.uid() via user_chat_context().
    const dataKind = detectDataQuery(nq);
    const chatCtx = dataKind ? await loadChatContext(userClient) : null;
    if (dataKind && chatCtx) {
      const { reply, intent } = dataReply(dataKind, chatCtx);
      return respond(user.id, reply, { intent });
    }

    // 4b. Guided ticket flow takes over once an order/payment issue is
    // detected — but only for the guided "other party not responding" flow
    // (its ticket schema). Anything with a rider/dispute/account shape was
    // already escalated above. Providers skip the guided flow (their issues
    // go to the appeal form with provider context — no direct contacts).
    const issueDetected = looksLikeIssue(nq) || session !== undefined;

    if (providerCtx.isProvider) {
      clearSession(user.id);
      if (issueDetected) {
        // Task 14: providers escalate through the appeal form with provider
        // context — no direct contact details.
        return respond(user.id, PROVIDER_DIRECT_REPLY, {
          handoff: true,
          intent: "appeal_provider",
          links: INTENT_ROUTES.appeal_provider,
        });
      }
    } else {
      if (session) {
        const draft: TicketDraft = session;
        const answerIdx = session.step;
        const answer = question;

        if (answerIdx === 0) draft.providerName = answer.slice(0, 120);
        else if (answerIdx === 1) draft.providerCity = answer.slice(0, 80);
        else if (answerIdx === 2) {
          const phone = normalizePhone(answer);
          if (!phone) {
            return json({ reply:
              "That doesn't look like an Ethiopian phone number. Please enter it " +
              "as 09xxxxxxxx or +2519xxxxxxxx." });
          }
          draft.reporterPhone = phone;
        } else if (answerIdx === 3) {
          const on = parseOrderNumber(answer);
          draft.orderNumber = on ?? (/\b(no|none|dont know|don't know|not sure|na)\b/i.test(answer) ? "NO" : null);
          if (!draft.orderNumber) {
            return json({ reply:
              "I couldn't find an order number in that. You can type it like Vh00012, " +
              "or write 'no' if you don't have it." });
          }
        } else if (answerIdx === 4) {
          draft.description = answer.slice(0, 2000);
        }

        draft.step = answerIdx + 1;
        if (draft.step < TICKET_STEPS) {
          setSession(user.id, draft);
          return json({ reply: TICKET_QUESTIONS[draft.step] });
        }

        // All five answers collected — submit the ticket.
        const ok = await submitTicket({
          userId: user.id,
          draft: draft as TicketInput["draft"],
        });
        clearSession(user.id);
        return ok
          ? respond(user.id, ticketThankYou(draft), { intent: "ticket" })
          : respond(
              user.id,
              "I couldn't submit your issue just now. Tap \"Submit an appeal\" " +
                "below instead — the appeal form reaches the same team and " +
                "works reliably.",
              { handoff: true, intent: "ticket", links: INTENT_ROUTES.appeal_dispute },
            );
      }

      if (issueDetected) {
        setSession(user.id, { step: 0 });
        return respond(user.id, TICKET_QUESTIONS[0], { intent: "ticket" });
      }
    }

    // 4c. 10-hour no-response fallback (users only — Behavior 4).
    const fallback = await maybeGiveFallback(user.id);
    if (fallback) return respond(user.id, fallback, { handoff: true });

    // 4d. Fast path: canned answers for the app's core flows.
    const canned = await cannedReply(nq, providerCtx.isProvider);
    if (canned) {
      return respond(user.id, canned, {
        intent: cannedIntent(nq),
        // Offer a few next steps instead of ending on a wall of text.
        suggestions: MAIN_SUGGESTIONS,
      });
    }

    // 4e. Retrieval over indexed docs/UI text.
    const hints = msgs.filter((m: { role: string }) => m.role === "user").map((m: { content: string }) => m.content);
    let hits = await search(question, 6);
    if (!hits.length && hints.length > 1) {
      hits = await search(hints.slice(-3).join(" "), 6);
    }
    // Server-side follow-up memory: resolves terse follow-ups ("and rides?")
    // against the user's recent messages even when the client sent none.
    if (!hits.length) {
      const ctxQuery = withRecentContext(user.id, question);
      if (ctxQuery !== question) {
        hits = await search(ctxQuery, 6);
      }
    }
    // Keyword fallback: short or keyword-style queries often miss
    // embedding-wise; a direct ilike pass over the same doc/UI-text corpus
    // rescues them (same security guarantees — service-role only, kinds
    // filter intact).
    if (!hits.length) {
      hits = await searchKeywords(nq, 6);
    }
    const answer = buildAnswer(question, hits);
    if (answer.handoff) {
      // A retrieval miss is NOT a dispute. Saying "submit an appeal" to
      // "what's the weather" was cold and misleading; the honest answer is
      // "I'm not sure yet, tell me more", with a clarification question, a
      // few ready-made topics, and the appeal form still one tap away for
      // anyone who would rather talk to a person.
      return respond(user.id, NOT_UNDERSTOOD_REPLY, {
        handoff: true,
        intent: "fallback",
        links: INTENT_ROUTES.appeal_general,
        suggestions: FALLBACK_SUGGESTIONS,
      });
    }
    return respond(user.id, answer.reply, { intent: null });
  } catch (e) {
    console.error("repo-chat failed:", e);
    // Task 14: even the crash path must not leak contacts — escalate to the
    // appeal flow with a generic tag.
    return json({
      reply: escalationReply({ about: "general" }),
      handoff: true,
      links: INTENT_ROUTES.appeal_general,
    });
  }
});
