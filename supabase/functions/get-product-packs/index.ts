import { createClient } from "npm:@supabase/supabase-js@2";

type LabelColor =
  | { type: 'solid'; value: string }
  | { type: 'linear-gradient'; colors: [string, string, ...string[]]; locations: [number, number, ...number[]];
      start: { x: number; y: number }; end: { x: number; y: number } };

export interface ProductPack {
  productId: number;
  packId: string;
  packName: string;
  value: number | null;
  labels: { label: string; color?: LabelColor | null }[];
  offerId: string | null;
  price: number | null;
  currency: string | null;
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

class InputError extends Error {}

/** PostgREST may encode numeric columns as JSON strings; Buy Votes requires a number. */
function asNullableNumber(value: unknown): number | null {
  if (value == null) return null;
  if (typeof value === "number") return Number.isFinite(value) ? value : null;
  if (typeof value === "string" && value.trim() !== "") {
    const n = Number(value);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

async function readProductId(req: Request): Promise<number> {
  let value: unknown = new URL(req.url).searchParams.get('atom_product_id');
  if (value === null && req.method === 'POST') {
    try { value = (await req.json())?.atom_product_id; }
    catch { throw new InputError('Invalid JSON request body.'); }
  }
  if ((typeof value !== 'string' && typeof value !== 'number') || !/^\d+$/.test(String(value))) {
    throw new InputError('atom_product_id must be a positive integer.');
  }
  const productId = Number(value);
  if (!Number.isSafeInteger(productId) || productId <= 0 || productId > 2147483647) {
    throw new InputError('atom_product_id must be a positive integer.');
  }
  return productId;
}

export function createHandler(load: (productId: number) => Promise<ProductPack[]>) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
    if (req.method !== "GET" && req.method !== "POST") return json({ ok: false, error: "Method not allowed" }, 405);
    try {
      const productId = await readProductId(req);
      const rows = await load(productId);
      // Return only the fields used by Buy Votes.
      const packs = rows.map((row) => ({
        productId: row.productId, packId: row.packId, packName: row.packName, value: row.value,
        labels: row.labels,
        offerId: row.offerId, price: asNullableNumber(row.price as unknown), currency: row.currency,
      }));
      return json({ ok: true, packs });
    } catch (error) {
      if (error instanceof InputError) return json({ ok: false, error: error.message }, 400);
      console.error("get-product-packs:", error);
      return json({ ok: false, error: "Unable to load product packs." }, 500);
    }
  };
}

export const handleRequest = createHandler(async (productId) => {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("Supabase server credentials not configured");
  const supabase = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await supabase.schema("backoffice").from("product_packs")
    .select("productId, packId, packName, value, labels, offerId, price, currency")
    .eq("productId", productId)
    .order("sortOrder").order("packId");
  if (error) throw error;
  return data ?? [];
});

Deno.serve(handleRequest);
