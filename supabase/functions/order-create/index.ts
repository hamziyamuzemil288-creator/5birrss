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
  // Part 10: the delivery PRICING INPUTS — never a fee. The fee is computed
  // here, by the same RPC the buyer's checkout quoted with, so the number on
  // the checkout screen and the number charged are one number.
  delivery_lat?: number;
  delivery_lng?: number;
  vehicle_category_id?: string;
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
      // Part 10: the provider's own registered point and city. Read here (with
      // the service key) rather than taken from the client: it is the point
      // the delivery distance is measured FROM, and the buyer may not even
      // read it — it is released only after a payment proof is verified.
      .select("id, status, location_lat, location_lng, city")
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

    // Phase 4: fulfillment mode (defaults to DELIVERY for old clients).
    const fulfillmentMode =
      body.fulfillment_mode === "SELF_PICKUP" ? "SELF_PICKUP" : "DELIVERY";
    if (fulfillmentMode === "DELIVERY" &&
        !(body.delivery_address ?? "").trim()) {
      return json({ error: "Delivery requires an address" }, 400);
    }

    // ── the delivery price ──
    //
    // Priced by quote_delivery_fee — the SAME reader the buyer's checkout
    // quoted with (FeeResolver.deliveryFee). That function resolves the
    // provider's own registered point, measures the distance to the buyer's
    // point and prices it delivery_base_fee + fee_ride_per_km(vehicle, city)
    // x distance_km. No arithmetic happens here, which is the point: a second
    // copy of the pricing rule is what makes a quoted price and a charged
    // price differ.
    //
    // The CAP is the one refusal this function must not soften. Past
    // max_delivery_distance_km the quote comes back ok=false with
    // BEYOND_MAX_DISTANCE, and the checkout has already bounced the buyer to
    // self-pickup — but a client that ignores that must not be handed a free
    // delivery at the product price, so the order is refused outright with the
    // server's own sentence.
    //
    // A fee is added ONLY when the server could price this delivery. When it
    // could not — the provider has published no point, or the buyer sent no
    // point — the order is placed at the product price and the reason is
    // logged, rather than charging a number nobody could justify. The buyer's
    // checkout shows the same sentence from the same function.
    let deliveryFee = 0;
    let deliveryQuoteNote: string | null = null;

    const lat = Number(body.delivery_lat);
    const lng = Number(body.delivery_lng);
    const hasBuyerPoint = Number.isFinite(lat) && Number.isFinite(lng) &&
      Math.abs(lat) <= 90 && Math.abs(lng) <= 180;

    if (fulfillmentMode === "DELIVERY" && hasBuyerPoint) {
      const { data: quote, error: quoteError } = await admin.rpc(
        "quote_delivery_fee",
        {
          p_provider_id: body.provider_id,
          p_delivery_lat: lat,
          p_delivery_lng: lng,
          p_vehicle_category_id: body.vehicle_category_id ?? null,
          p_city: null,
        },
      );

      if (quoteError) {
        // Not fatal: an order at the product price is still an order the buyer
        // asked for. Logged so a real fault (a missing grant) is visible.
        console.error("order-create: delivery quote failed", quoteError);
      } else {
        const q = (quote ?? {}) as {
          ok?: boolean;
          fee?: unknown;
          distance_km?: unknown;
          reason?: string;
          message?: string;
        };
        const fee = Number(q.fee);
        if (q.ok === true && Number.isFinite(fee) && fee >= 0) {
          deliveryFee = Math.round(fee * 100) / 100;
          deliveryQuoteNote =
            `Delivery fee: ${deliveryFee.toFixed(2)}` +
            (body.vehicle_category_id ? ` (vehicle ${body.vehicle_category_id})` : "") +
            (q.distance_km != null ? `, ${q.distance_km} km` : "");
        } else if (q.reason === "BEYOND_MAX_DISTANCE") {
          // Delivered as a refusal, not a warning: a delivery too far away is
          // not a delivery this platform sells.
          const beyond = q.message;
          return json(
            {
              error:
                beyond ??
                "This delivery is beyond the maximum delivery distance. Choose self-pickup instead.",
            },
            400,
          );
        } else {
          console.warn(
            "order-create: delivery could not be priced",
            q.reason,
          );
        }
      }
    } else if (fulfillmentMode === "DELIVERY") {
      console.warn(
        "order-create: DELIVERY with no buyer point — order placed at the product price",
      );
    }

    const total = Math.round((subtotal + deliveryFee) * 100) / 100;

    // 4. Atomic write via SECURITY DEFINER SQL function.
    const itemsPayload = cleanedItems.map((item) => ({
      product_id: item.product_id,
      quantity: item.quantity,
      unit_price: unitPriceOf(productById.get(item.product_id)!), // server value
    }));

    // The delivery fee is recorded on the order's own note as well as in its
    // total, so the provider's and the buyer's order screens can state what
    // part of the amount was the trip.
    const noteWithDelivery = [body.note ?? "", deliveryQuoteNote ?? ""]
      .map((s) => s.trim())
      .filter((s) => s.length > 0)
      .join(" | ");

    const { data: created, error: rpcError } = await admin.rpc(
      "create_order_secure",
      {
        p_user_id: user.id,
        p_provider_id: body.provider_id,
        p_items: itemsPayload,
        p_total_amount: total,
        p_currency: currency,
        p_note: noteWithDelivery.length > 0 ? noteWithDelivery : null,
        p_fulfillment_mode: fulfillmentMode,
        p_delivery_address: body.delivery_address ?? null,
        p_city: null,
      }
    );

    if (rpcError) {
      console.error("order-create: create_order_secure failed", rpcError);
      return json({ error: sanitizeError(rpcError.message) }, 400);
    }

    // ── WHERE this delivery goes ──
    //
    // The point above was a PRICING input; this is the order's own record of
    // the destination. Without it the driver has no drop-off to navigate to
    // and the buyer's tracking screen has no pin — and the address line on its
    // own is a street name, not a coordinate. Stored by the server (service
    // role) rather than added to create_order_secure's signature, which every
    // assertion in the repository pins. A failure here is logged and leaves
    // the order standing: the delivery address text is already on the order.
    const createdId = (created as { id?: string } | null)?.id;
    if (createdId && fulfillmentMode === "DELIVERY" && hasBuyerPoint) {
      const { error: destError } = await admin
        .from("orders")
        .update({ delivery_dest_lat: lat, delivery_dest_lng: lng })
        .eq("id", createdId);
      if (destError) {
        console.error(
          "order-create: delivery destination was not stored",
          destError,
        );
      }
    }

    return json(
      {
        order: created,
        // Additive: the client can show what the trip cost without re-deriving
        // it. Absent (0) when the delivery could not be priced.
        delivery_fee: deliveryFee,
      },
      201,
    );
  } catch (e) {
    // Structured: the server log keeps the real cause, the client gets a
    // plain sentence and a request_id it can quote. Previously this returned
    // a bare string and the correlation to the log line was by timestamp
    // alone, which does not work on a busy day.
    return handleCatch(e, "order-create:create");
  }
});
