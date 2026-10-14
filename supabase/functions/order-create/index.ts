// POST /order-create
// Body: { provider_id, items: [{ product_id, quantity }], note? }
//
// Server-side, price-authoritative order creation.
//
// Replaces the client-trusted flow in lib/core/repositories/order_repository.dart
// (createOrder), which previously sent `totalAmount` and `order_items.unit_price`
// straight from the Flutter client into the `orders` / `order_items` tables.
//
// This function:
//   1. Authenticates the caller (must be a logged-in USER, not a provider/admin).
//   2. Accepts only { provider_id, items: [{ product_id, quantity }] } — no prices.
//   3. Looks up each product's current price, provider ownership, availability,
//      and stock server-side.
//   4. Computes the subtotal / total itself.
//   5. Inserts the order + order_items atomically via a SECURITY DEFINER SQL
//      function (create_order_secure), so partial writes can't happen.
//   6. Returns the created order (with server-computed total) to the client.
//
// Deploy: supabase functions deploy order-create
// Requires the SQL function `create_order_secure` (see 0005_secure_order_creation.sql)
// to be applied as a migration first.

import {
  corsHeaders,
  requireUser,
  getAdminClient,
  json,
  sanitizeError,
} from "../_shared/client.ts";
import { handleCatch } from "../_shared/errors.ts";

interface OrderItemInput {
  product_id: string;
  quantity: number;
}

interface OrderCreateBody {
  provider_id: string;
  items: OrderItemInput[];
  note?: string;
  // Phase 4: fulfillment selection (additive, optional).
  fulfillment_mode?: "DELIVERY" | "SELF_PICKUP";
  delivery_address?: string;
}

const MAX_ITEMS_PER_ORDER = 50;
const MAX_QUANTITY_PER_ITEM = 999;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // 1. Authenticate — this throws/returns a 401 Response if invalid.
    const { user } = await requireUser(req);

    // 2. Parse + validate the request shape. No price fields accepted at all.
    let body: OrderCreateBody;
    try {
      body = await req.json();
    } catch {
      return json({ error: "Invalid JSON body" }, 400);
    }

    if (!body.provider_id || typeof body.provider_id !== "string") {
      return json({ error: "provider_id is required" }, 400);
    }
    if (!Array.isArray(body.items) || body.items.length === 0) {
      return json({ error: "items must be a non-empty array" }, 400);
    }
    if (body.items.length > MAX_ITEMS_PER_ORDER) {
      return json(
        { error: `items cannot exceed ${MAX_ITEMS_PER_ORDER}` },
        400
      );
    }

    const cleanedItems: { product_id: string; quantity: number }[] = [];
    for (const raw of body.items) {
      if (!raw || typeof raw.product_id !== "string") {
        return json({ error: "Each item requires a product_id" }, 400);
      }
      const qty = Number(raw.quantity);
      // Fractional amounts are valid for unit-priced listings (per kg/liter);
      // the order_items.quantity column is numeric(10,3) (migration 0040).
      if (
        !Number.isFinite(qty) ||
        qty <= 0 ||
        qty > MAX_QUANTITY_PER_ITEM ||
        Math.round(qty * 1000) !== qty * 1000
      ) {
        return json(
          { error: `Invalid quantity for product ${raw.product_id}` },
          400
        );
      }
      cleanedItems.push({ product_id: raw.product_id, quantity: qty });
    }

    // Reject duplicate product_ids — force the client to send one line per product.
    const seen = new Set<string>();
    for (const item of cleanedItems) {
      if (seen.has(item.product_id)) {
        return json({ error: `Duplicate product_id: ${item.product_id}` }, 400);
      }
      seen.add(item.product_id);
    }

    // 3. Use the service-role client for the authoritative price lookup and
    // the atomic write — but only AFTER we've verified the caller's identity
    // above via requireUser(). The user's own id (never client-supplied) is
    // passed through as the order owner.
    const admin = getAdminClient();

    // The provider must be APPROVED before any order is accepted.
    //
    // Search already hides a non-approved provider's products (the search
    // functions join provider_profiles on status = 'APPROVED') and a trigger
    // stops a suspended provider from publishing new listings, but neither
    // retracts listings that were already ACTIVE. A customer holding a
    // direct link to a product page, or an item already sitting in their
    // cart from before the suspension, could still place the order — so a
    // suspended provider kept taking work and earning fees.
    //
    // Checked before the item loop so the refusal is one clear message
    // rather than a per-product "not available" that reads like the item
    // sold out.
    const { data: provider, error: providerError } = await admin
      .from("provider_profiles")
      .select("id, status")
      .eq("id", body.provider_id)
      .maybeSingle();

    if (providerError) {
      console.error("order-create: provider lookup failed", providerError);
      return json({ error: "Failed to validate the provider" }, 500);
    }
    if (!provider) {
      return json({ error: "Provider not found" }, 404);
    }
    if (provider.status !== "APPROVED") {
      return json(
        {
          error:
            "This provider is not currently accepting orders. Please try again later.",
        },
        409
      );
    }

    const productIds = cleanedItems.map((i) => i.product_id);
    const { data: products, error: productsError } = await admin
      .from("products")
      .select(
        // 20261014000002: display_price is the PUBLIC price every screen shows
        // (generated column: provider price + 5 + 1.9%). The raw `price` is
        // kept only as a fallback for the window before that migration is
        // applied — the buyer must never be charged a number no screen showed.
        "id, provider_id, price, display_price, currency, is_active, is_available, stock_quantity, listing_status"
      )
      .in("id", productIds);

    if (productsError) {
      console.error("order-create: product lookup failed", productsError);
      return json({ error: "Failed to validate order items" }, 500);
    }

    if (!products || products.length !== cleanedItems.length) {
      return json({ error: "One or more products could not be found" }, 400);
    }

    const productById = new Map(products.map((p) => [p.id, p]));

    // The authoritative unit price of one listing: the generated public
    // price, falling back to the raw price only while the column is absent.
    const unitPriceOf = (product: {
      price?: unknown;
      display_price?: unknown;
    }): number => {
      const display = Number(product.display_price);
      return Number.isFinite(display) && product.display_price !== null
        ? display
        : Number(product.price);
    };

    let subtotal = 0;
    let currency: string | null = null;

    for (const item of cleanedItems) {
      const product = productById.get(item.product_id)!;

      // All items must belong to the provider the order is being placed with.
      if (product.provider_id !== body.provider_id) {
        return json(
          {
            error: `Product ${item.product_id} does not belong to provider ${body.provider_id}`,
          },
          400
        );
      }

      if (!product.is_active || !product.is_available) {
        return json(
          { error: `Product ${item.product_id} is not currently available` },
          409
        );
      }

      if (product.listing_status && product.listing_status !== "ACTIVE") {
        return json(
          {
            error: `Product ${item.product_id} is not active (${product.listing_status})`,
          },
          409
        );
      }

      if (
        product.stock_quantity !== null &&
        product.stock_quantity !== undefined &&
        product.stock_quantity < Math.ceil(item.quantity)
      ) {
        return json(
          { error: `Insufficient stock for product ${item.product_id}` },
          409
        );
      }

      if (currency === null) {
        currency = product.currency ?? "ETB";
      } else if (product.currency && product.currency !== currency) {
        return json(
          { error: "All items in one order must use the same currency" },
          400
        );
      }

      // Server-authoritative price — client-supplied prices are never read,
      // and the number charged is the same display price every public card,
      // cart line and checkout total shows (20261014000002).
      subtotal += unitPriceOf(product) * item.quantity;
    }

    const total = Math.round(subtotal * 100) / 100; // round to cents/kobo-equivalent

    // 4. Atomic write via SECURITY DEFINER SQL function.
    const itemsPayload = cleanedItems.map((item) => ({
      product_id: item.product_id,
      quantity: item.quantity,
      unit_price: unitPriceOf(productById.get(item.product_id)!), // server value
    }));

    // Phase 4: fulfillment mode (defaults to DELIVERY for old clients).
    const fulfillmentMode =
      body.fulfillment_mode === "SELF_PICKUP" ? "SELF_PICKUP" : "DELIVERY";
    if (fulfillmentMode === "DELIVERY" &&
        !(body.delivery_address ?? "").trim()) {
      return json({ error: "Delivery requires an address" }, 400);
    }

    const { data: created, error: rpcError } = await admin.rpc(
      "create_order_secure",
      {
        p_user_id: user.id,
        p_provider_id: body.provider_id,
        p_items: itemsPayload,
        p_total_amount: total,
        p_currency: currency,
        p_note: body.note ?? null,
        p_fulfillment_mode: fulfillmentMode,
        p_delivery_address: body.delivery_address ?? null,
        p_city: null,
      }
    );

    if (rpcError) {
      console.error("order-create: create_order_secure failed", rpcError);
      return json({ error: sanitizeError(rpcError.message) }, 400);
    }

    return json({ order: created }, 201);
  } catch (e) {
    // Structured: the server log keeps the real cause, the client gets a
    // plain sentence and a request_id it can quote. Previously this returned
    // a bare string and the correlation to the log line was by timestamp
    // alone, which does not work on a busy day.
    return handleCatch(e, "order-create:create");
  }
});
